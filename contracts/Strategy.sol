// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/MasterChef.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 internal constant weth = IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IBalancerVault public balancerVault;
    IBalancerPool public bpt;
    IERC20 public rewardToken;
    IAsset[] internal assets;
    SwapSteps internal swapSteps;
    uint256[] internal minAmountsOut;
    bytes32 public balancerPoolId;
    uint8 public numTokens;
    uint8 public tokenIndex;
    bool internal abandonRewards;

    // masterchef
    IBeethovenxMasterChef public masterChef;

    struct SwapSteps {
        bytes32[] poolIds;
        IAsset[] assets;
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
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0);
        bpt = IBalancerPool(_balancerPool);
        balancerPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(balancerPoolId);
        numTokens = uint8(tokens.length);
        assets = new IAsset[](numTokens);
        tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < numTokens; i++) {
            if (tokens[i] == want) {
                tokenIndex = i;
            }
            assets[i] = IAsset(address(tokens[i]));
        }
        require(tokenIndex != type(uint8).max, "token not in pool!");

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleDeposit = _maxSingleDeposit.mul(10 ** uint256(ERC20(address(want)).decimals()));
        minAmountsOut = new uint256[](numTokens);
        minDepositPeriod = _minDepositPeriod;
        masterChefPoolId = _masterChefPoolId;
        masterChef = IBeethovenxMasterChef(_masterChef);
        require(masterChef.lpTokens(masterChefPoolId) == address(bpt));

        want.safeApprove(address(balancerVault), max);
        bpt.approve(address(masterChef), max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("SSBEETv2 ", ERC20(address(want)).symbol(), " ", bpt.symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPooled());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        _collectTradingFees();
        // claim beets
        _claimRewards();
        // sell the % not staking
        _sellRewards();

        uint256 afterWant = balanceOfWant();
        _profit = afterWant.sub(beforeWant);
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _debtPayment += _loss;
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _debtPayment += _profit;
            _profit = 0;
        }

        // final check to make sure accounting is correct
        require(_debtOutstanding == _debtPayment.add(_loss));
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now - lastDepositTime < minDepositPeriod) {
            return;
        }

        // put want into lp then put want-lp into masterchef
        uint256 pooledBefore = balanceOfPooled();
        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());
        if (joinPool(amountIn, assets, numTokens, tokenIndex, balancerPoolId)) {
            // put all want-lp into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        if (estimatedTotalAssets() < _amountNeeded) {
            _liquidatedAmount = liquidateAllPositions();
            return (_liquidatedAmount, _amountNeeded.sub(_liquidatedAmount));
        }

        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            uint256 toExitAmount = _amountNeeded.sub(looseAmount);

            // withdraw all bpt out of masterchef
            masterChef.withdrawAndHarvest(masterChefPoolId, balanceOfBptInMasterChef(), address(this));
            // sell some bpt
            _sellBpt(tokensToBpts(toExitAmount), assets, tokenIndex, balancerPoolId, minAmountsOut, balanceOfBpt());
            // put remaining bpt back into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);

            _enforceSlippageOut(toExitAmount, _liquidatedAmount.sub(looseAmount));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 liquidated) {
        uint totalDebt = vault.strategies(address(this)).totalDebt;

        masterChef.withdrawAndHarvest(masterChefPoolId, balanceOfBptInMasterChef(), address(this));
        // sell all bpt
        _sellBpt(balanceOfBpt(), assets, tokenIndex, balancerPoolId, minAmountsOut, balanceOfBpt());

        liquidated = balanceOfWant();
        _enforceSlippageOut(totalDebt, liquidated);

        return liquidated;
    }

    // note that this withdraws into newStrategy.
    function prepareMigration(address _newStrategy) internal override {
        _withdrawFromMasterChef(_newStrategy, balanceOfBptInMasterChef(), masterChefPoolId);
        uint256 rewards = balanceOfReward();
        if (rewards > 0) {
            rewardToken.transfer(_newStrategy, rewards);
        }
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view override returns (uint256){}

    function tendTrigger(uint256 callCostInWei) public view override returns (bool) {
        return now.sub(lastDepositTime) > minDepositPeriod && balanceOfWant() > 0;
    }

    // HELPERS //

    function withdrawFromMasterChef(uint256 _amount, uint256 _masterChefPooId) external onlyVaultManagers {
        _withdrawFromMasterChef(address(this), _amount, _masterChefPooId);
    }

    // AbandonRewards withdraws lp without rewards. Specify where to withdraw to
    function _withdrawFromMasterChef(address _to, uint256 _amount, uint256 _masterChefPoolId) internal {
        if (_amount > 0) {
            abandonRewards
            ? masterChef.emergencyWithdraw(_masterChefPoolId, address(_to))
            : masterChef.withdrawAndHarvest(_masterChefPoolId, _amount, address(_to));
        }
    }

    // claim all beets rewards from masterchef
    function _claimRewards() internal {
        masterChef.harvest(masterChefPoolId, address(this));
    }

    function _sellRewards() internal {
        uint256 amount = balanceOfReward();
        uint decReward = ERC20(address(rewardToken)).decimals();
        uint decWant = ERC20(address(want)).decimals();

        if (amount > 10 ** (decReward > decWant ? decReward.sub(decWant) : 0)) {
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

    function _collectTradingFees() internal {
        uint256 total = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (total > debt) {
            // withdraw all bpt out of masterchef
            masterChef.withdrawAndHarvest(masterChefPoolId, balanceOfBptInMasterChef(), address(this));
            uint256 profit = total.sub(debt);
            _sellBpt(tokensToBpts(profit), assets, tokenIndex, balancerPoolId, minAmountsOut, balanceOfBpt());
            // put remaining bpt back into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));
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

    function balanceOfReward() public view returns (uint256 _amount){
        return rewardToken.balanceOf(address(this));
    }

    // returns an estimate of want tokens based on bpt balance
    function balanceOfPooled() public view returns (uint256 _amount){
        return bptsToTokens(balanceOfBpt().add(balanceOfBptInMasterChef()));
    }

    function pendingRewards() public view returns (uint256 _amount){
        return masterChef.pendingBeets(masterChefPoolId, address(this));
    }

    /// use bpt rate to estimate equivalent amount of want.
    function bptsToTokens(uint _amountBpt) public view returns (uint _amount){
        uint unscaled = _amountBpt * bpt.getRate() / 1e18;
        return _scaleDecimals(unscaled, ERC20(address(bpt)), ERC20(address(want)));
    }

    function tokensToBpts(uint _amountTokens) public view returns (uint _amount){
        uint unscaled = _amountTokens * 1e18 / bpt.getRate();
        return _scaleDecimals(unscaled, ERC20(address(want)), ERC20(address(bpt)));
    }

    function _scaleDecimals(uint _amount, ERC20 _fromToken, ERC20 _toToken) internal view returns (uint _scaled){
        uint decFrom = _fromToken.decimals();
        uint decTo = _toToken.decimals();
        return decTo > decFrom ? _amount * 10 ** (decTo.sub(decFrom)) : _amount / 10 ** (decFrom.sub(decTo));
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
    function sellBpt(uint256 _amountBpts, IAsset[] memory _assets, uint256 _tokenIndex, bytes32 _balancerPoolId, uint256[] memory _minAmountsOut, uint256 _maxBpts) external onlyVaultManagers {
        _sellBpt(_amountBpts, _assets, _tokenIndex, _balancerPoolId, _minAmountsOut, _maxBpts);
    }

    // sell bpt for want at current bpt rate
    function _sellBpt(uint256 _amountBpts, IAsset[] memory _assets, uint256 _tokenIndex, bytes32 _balancerPoolId, uint256[] memory _minAmountsOut, uint256 _maxBpts) internal {
        if (_amountBpts > 0) {
            bytes memory userData = abi.encode(IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT, Math.min(_amountBpts, _maxBpts), _tokenIndex);
            IBalancerVault.ExitPoolRequest memory request = IBalancerVault.ExitPoolRequest(_assets, _minAmountsOut, userData, false);
            balancerVault.exitPool(_balancerPoolId, address(this), address(this), request);
        }
    }

    // join pool given exact token in
    function joinPool(uint256 _amountIn, IAsset[] memory _assets, uint256 _numTokens, uint256 _tokenIndex, bytes32 _poolId) internal returns (bool _joined){
        uint256 expectedBptOut = tokensToBpts(amountIn).mul(basisOne.sub(maxSlippageIn)).div(basisOne);
        uint256[] memory maxAmountsIn = new uint256[](_numTokens);
        maxAmountsIn[_tokenIndex] = _amountIn;
        if (_amountIn > 0) {
            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, expectedBptOut);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(_assets, maxAmountsIn, userData, false);
            balancerVault.joinPool(_poolId, address(this), address(this), request);
            lastDepositTime = now;
            return true;
        }
        return false;
    }

    function whitelistReward(address _rewardToken, SwapSteps memory _steps) public onlyVaultManagers {
        rewardToken = IERC20(_rewardToken);
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

    // revert if slippage out exceeds our requirement
    function _enforceSlippageOut(uint _intended, uint _actual) internal view {
        // enforce that amount exited didn't slip beyond our tolerance
        // just in case there's positive slippage
        uint256 exitSlipped = _intended > _actual ? _intended.sub(_actual) : 0;
        uint256 maxLoss = _intended.mul(maxSlippageOut).div(basisOne);
        require(exitSlipped <= maxLoss, "Slipped Out!");
    }

    // swap step contains information on multihop sells
    function getSwapSteps() public view returns (SwapSteps memory){
        return swapSteps;
    }

    // masterchef contract in case of masterchef migration
    function setMasterChef(address _masterChef) public onlyGovernance {
        _withdrawFromMasterChef(address(this), balanceOfBptInMasterChef(), masterChefPoolId);

        bpt.approve(address(masterChef), 0);
        masterChef = IBeethovenxMasterChef(_masterChef);
        bpt.approve(address(masterChef), max);
    }

    // toggle for whether to abandon rewards or not on emergency withdraws from masterchef
    function setAbandonRewards(bool abandon) external onlyVaultManagers {
        abandonRewards = abandon;

    // Balancer requires this contract to be payable, so we add ability to sweep stuck ETH
    function sweepETH() public onlyGovernance {
        (bool success, ) = governance().call{value: address(this).balance}("");
        require(success,"!FailedETHSweep");
    }

    receive() external payable {}
}

