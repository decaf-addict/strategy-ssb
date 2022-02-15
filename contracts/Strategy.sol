// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/MasterChef.sol";

contract Strategy is BaseStrategy {

    IBalancerVault public balancerVault;
    IBalancerPool public bpt;
    IERC20 public rewardToken;
    IAsset[] internal assets;
    SwapSteps internal swapSteps;
    bytes32 public balancerPoolId;
    uint8 internal numTokens;
    uint8 internal tokenIndex;
    Toggles public toggles;

    // The keep mechanism is intended for governance voting purposes. Strategy will route a percentage (default 10%)
    // to the governance or eventually a voter proxy in order to slowly amass voting power for Beethoven pool gauges
    address public keep;
    uint256 public keepBips;

    // masterchef
    IBeethovenxMasterChef public masterChef;

    struct SwapSteps {
        bytes32[] poolIds;
        IAsset[] assets;
    }

    struct Toggles {
        bool claimRewards;
        bool doSellRewards;
        bool abandonRewards;
    }

    uint256 internal constant max = type(uint256).max;

    //1	    0.01%
    //5	    0.05%
    //10	0.1%
    //50	0.5%
    //100	1%
    //1000	10%
    //10000	100%
    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips
    uint256 public maxSingleDeposit;
    uint256 public minDepositPeriod; // seconds
    uint256 public lastDepositTime;
    uint256 public masterChefPoolId;
    uint256 internal constant basisOne = 10000;

    constructor(
        address _vault,
        address _balancerVault,
        address _balancerPool,
        address _masterChef,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod,
        uint256 _masterChefPoolId)
    public BaseStrategy(_vault){
        _initializeStrat(
            _vault,
            _balancerVault,
            _balancerPool,
            _masterChef,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleDeposit,
            _minDepositPeriod,
            _masterChefPoolId);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _balancerVault,
        address _balancerPool,
        address _masterChef,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod,
        uint256 _masterChefPoolId
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(
            _vault,
            _balancerVault,
            _balancerPool,
            _masterChef,
            _maxSlippageIn,
            _maxSlippageOut,
            _maxSingleDeposit,
            _minDepositPeriod,
            _masterChefPoolId
        );
    }

    function _initializeStrat(
        address _vault,
        address _balancerVault,
        address _balancerPool,
        address _masterChef,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod,
        uint256 _masterChefPoolId
    ) internal {
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0);
        bpt = IBalancerPool(_balancerPool);
        balancerPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(balancerPoolId);
        require(tokens.length > 0, "empty");
        numTokens = uint8(tokens.length);
        assets = new IAsset[](numTokens);
        tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < numTokens; i++) {
            if (tokens[i] == want) {
                tokenIndex = i;
            }
            assets[i] = IAsset(address(tokens[i]));
        }
        require(tokenIndex != type(uint8).max, "!inPool");

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleDeposit = _maxSingleDeposit.mul(10 ** uint256(ERC20(address(want)).decimals()));
        minDepositPeriod = _minDepositPeriod;
        masterChefPoolId = _masterChefPoolId;
        masterChef = IBeethovenxMasterChef(_masterChef);
        require(masterChef.lpTokens(masterChefPoolId) == address(bpt));

        want.safeApprove(address(balancerVault), max);
        bpt.approve(address(masterChef), max);

        // 10%t to chad by default
        keep = governance();
        keepBips = 1000;

        toggles = Toggles({claimRewards : true, doSellRewards : true, abandonRewards : false});
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("ssbeetV2 ", ERC20(address(want)).symbol(), " ", bpt.symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPooled());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if(toggles.claimRewards){
            _claimRewards();
        }
        if (toggles.doSellRewards) {
            _sellRewards();
        }

        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit.sub(totalDebt)
            : 0;

        uint256 _amountFreed;
        uint256 _toLiquidate = _debtOutstanding.add(_profit);
        if (_toLiquidate > 0) {
            (_amountFreed, _loss) = liquidatePosition(_toLiquidate);
        }

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 100, _loss 50
            // loss should be 0, (50-50)
            // profit should endup in 0
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 140, _loss 10
            // _profit should be 40, (50 profit - 10 loss)
            // loss should end up in 0
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now.sub(lastDepositTime) < minDepositPeriod) {
            return;
        }

        // put want into lp then put want-lp into masterchef
        if (_joinPool()) {
            // put all want-lp into masterchef
            _depositIntoMasterChef(balanceOfBpt());
        }
    }

    function depositIntoMasterChef(uint _bpts) external onlyVaultManagers {
        _depositIntoMasterChef(_bpts);
    }

    function _depositIntoMasterChef(uint _bpts) internal {
        masterChef.deposit(masterChefPoolId, _bpts, address(this));
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            // convert amount still needed to bpt
            uint256 toExitAmount = tokensToBpts(_amountNeeded.sub(looseAmount));
            // withdraw needed bpt out of masterchef and sell it for want
            _withdrawFromMasterChefAndSellBpt(toExitAmount);

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
        require(_amountNeeded == _liquidatedAmount.add(_loss), "!check");
    }

    function liquidateAllPositions() internal override returns (uint256 liquidated) {
        _withdrawFromMasterChef(address(this), balanceOfBptInMasterChef());
        // sell all bpt
        _sellBpt(balanceOfBpt());
        liquidated = balanceOfWant();
    }

    // note that this withdraws into newStrategy.
    function prepareMigration(address _newStrategy) internal override {
        _withdrawFromMasterChef(_newStrategy, balanceOfBptInMasterChef());
        uint256 _balanceOfBpt = balanceOfBpt();
        if (_balanceOfBpt > 0) {
            bpt.transfer(_newStrategy, _balanceOfBpt);
        }
        uint256 rewards = balanceOfReward();
        if (rewards > 0) {
            rewardToken.safeTransfer(_newStrategy, rewards);
        }
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view override returns (uint256){}

    function tendTrigger(uint256 callCostInWei) public view override returns (bool) {
        return now.sub(lastDepositTime) > minDepositPeriod && balanceOfWant() > 0;
    }

    // HELPERS //

    function withdrawFromMasterChef(uint256 _amountBpt) external onlyVaultManagers {
        _withdrawFromMasterChef(address(this), _amountBpt);
    }

    // AbandonRewards withdraws lp without rewards. Specify where to withdraw to
    function _withdrawFromMasterChef(address _to, uint256 _amountBpt) internal {
        _amountBpt = Math.min(balanceOfBptInMasterChef(), _amountBpt);
        if (_amountBpt > 0) {
            toggles.abandonRewards
                ? masterChef.emergencyWithdraw(masterChefPoolId, address(_to))
                : masterChef.withdrawAndHarvest(masterChefPoolId, _amountBpt, address(_to));
        }
    }

    // Withdraw the desired amount in bpt from masterchef and sell it for want
    function _withdrawFromMasterChefAndSellBpt(uint256 _amountBpt) internal {
        // don't try to withdraw more than what we have in masterchef
        _amountBpt = Math.min(_amountBpt, balanceOfBptInMasterChef());

        // withdraw the desired amount out of masterchef
        _withdrawFromMasterChef(address(this), _amountBpt);

        // sell the desired amount for want
        _sellBpt(_amountBpt);
    }

    function claimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    // claim all beets rewards from masterchef
    function _claimRewards() internal {
        if (getPendingBeets() > 0) {
            uint256 rewardBal = balanceOfReward();
            masterChef.harvest(masterChefPoolId, address(this));
            uint256 keepBal = balanceOfReward().sub(rewardBal).mul(keepBips).div(basisOne);
            if (keepBal > 0) {
                rewardToken.safeTransfer(keep, keepBal);
            }
        }
    }

    function sellRewards() external onlyVaultManagers {
        _sellRewards();
    }

    function _sellRewards() internal {
        uint256 amount = balanceOfReward();
        if (amount > 0) {
            uint length = swapSteps.poolIds.length;
            IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](length);
            int[] memory limits = new int[](length + 1);
            limits[0] = int(amount);
            for (uint j = 0; j < length; j++) {
                steps[j] = IBalancerVault.BatchSwapStep(swapSteps.poolIds[j],
                    j,
                    j + 1,
                    j == 0 ? amount : 0,
                    abi.encode(0)
                );
            }
            balancerVault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN,
                steps,
                swapSteps.assets,
                IBalancerVault.FundManagement(address(this), false, address(this), false),
                limits,
                now + 10);
        }
    }

    function balanceOfWant() public view returns (uint256 _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfBpt() public view returns (uint256 _amount){
        return bpt.balanceOf(address(this));
    }

    function balanceOfBptInMasterChef() public view returns (uint256 _amount){
        (_amount,) = masterChef.userInfo(masterChefPoolId, address(this));
    }

    function getPendingBeets() public view returns (uint256){
        return masterChef.pendingBeets(masterChefPoolId, address(this));
    }

    function balanceOfReward() public view returns (uint256 _amount){
        return rewardToken.balanceOf(address(this));
    }

    // returns an estimate of want tokens based on bpt balance
    function balanceOfPooled() public view returns (uint256 _amount){
        return bptsToTokens(balanceOfBpt().add(balanceOfBptInMasterChef()));
    }

    /// use bpt rate to estimate equivalent amount of want.
    function bptsToTokens(uint _amountBpt) public view returns (uint _amount){
        uint unscaled = _amountBpt.mul(bpt.getRate()).div(1e18);
        return _scaleDecimals(unscaled, ERC20(address(bpt)), ERC20(address(want)));
    }

    function tokensToBpts(uint _amountTokens) public view returns (uint _amount){
        uint unscaled = _amountTokens.mul(1e18).div(bpt.getRate());
        return _scaleDecimals(unscaled, ERC20(address(want)), ERC20(address(bpt)));
    }

    function _scaleDecimals(uint _amount, ERC20 _fromToken, ERC20 _toToken) internal view returns (uint _scaled){
        uint decFrom = _fromToken.decimals();
        uint decTo = _toToken.decimals();
        return decTo > decFrom ? _amount.mul(10 ** (decTo.sub(decFrom))) : _amount.div(10 ** (decFrom.sub(decTo)));
    }

    function _getSwapRequest(IERC20 token, uint256 amount, uint256 lastChangeBlock) internal view returns (IBalancerPool.SwapRequest memory request){
        return IBalancerPool.SwapRequest(IBalancerPool.SwapKind.GIVEN_IN,
            token,
            want,
            amount,
            balancerPoolId,
            lastChangeBlock,
            address(this),
            address(this),
            abi.encode(0)
        );
    }

    // this allows us to also sell stakedBpts externally
    function sellBpt(uint256 _amountBpts) external onlyVaultManagers {
        _sellBpt(_amountBpts);
    }

    // sell bpt for want at current bpt rate
    function _sellBpt(uint256 _amountBpts) internal {
        _amountBpts = Math.min(_amountBpts, balanceOfBpt());
        if (_amountBpts > 0) {
            uint256[] memory minAmountsOut = new uint256[](numTokens);
            minAmountsOut[tokenIndex] = bptsToTokens(_amountBpts).mul(basisOne.sub(maxSlippageOut)).div(basisOne);
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, _amountBpts, tokenIndex);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(assets, minAmountsOut, userData, false);
            balancerVault.exitPool(balancerPoolId, address(this), address(this), request);
        }
    }

    // join pool given exact token in
    function _joinPool() internal returns (bool _joined){
        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());
        if (amountIn > 0) {
            uint256 expectedBptOut = tokensToBpts(amountIn).mul(basisOne.sub(maxSlippageIn)).div(basisOne);
            uint256[] memory maxAmountsIn = new uint256[](numTokens);
            maxAmountsIn[tokenIndex] = amountIn;
            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, expectedBptOut);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
            balancerVault.joinPool(balancerPoolId, address(this), address(this), request);
            lastDepositTime = now;
            return true;
        }
        return false;
    }

    function whitelistReward(address _rewardToken, SwapSteps memory _steps) public onlyVaultManagers {
        rewardToken = IERC20(_rewardToken);
        rewardToken.approve(address(balancerVault), 0);
        rewardToken.approve(address(balancerVault), max);
        swapSteps = _steps;
    }

    function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut, uint256 _maxSingleDeposit, uint256 _minDepositPeriod) public onlyVaultManagers {
        require(_maxSlippageIn <= basisOne);
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne);
        maxSlippageOut = _maxSlippageOut;

        maxSingleDeposit = _maxSingleDeposit;
        minDepositPeriod = _minDepositPeriod;
    }

    function setToggles(bool _claimRewards, bool _doSellRewards, bool _abandon) external onlyVaultManagers {
        toggles.claimRewards = _claimRewards;
        toggles.doSellRewards = _doSellRewards;
        toggles.abandonRewards = _abandon;
    }

    // swap step contains information on multihop sells
    function getSwapSteps() public view returns (SwapSteps memory){
        return swapSteps;
    }

    function setKeepParams(address _keep, uint _keepBips) external onlyGovernance {
        require(keepBips <= basisOne);
        keep = _keep;
        keepBips = _keepBips;
    }

    // Balancer requires this contract to be payable, so we add ability to sweep stuck ETH
    function sweepETH() public onlyGovernance {
        (bool success,) = governance().call{value : address(this).balance}("");
        require(success, "eth");
    }

    receive() external payable {}
}
