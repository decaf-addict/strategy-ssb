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

interface IName {
    function name() external view returns (string memory);
}

/// @dev Boosted pool token (bpt): Primary pool that the linear pool integrates into. For boosted pools, bpt is preminted. Instead of joining/exiting
/// pool with want, we have to swap for it.
/// Linear pool token (lpt): Primary linear pool that the strategy interacts with to wrap/unwrap want token
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IBalancerVault public balancerVault;
    IStablePhantomPool public bpt;
    ILinearPool public lpt;
    IERC20[] public rewardTokens;
    SwapSteps[] internal swapSteps;
    bytes32 public balancerPoolId;

    bool public doSellRewards;

    struct SwapSteps {
        bytes32[] poolIds;
        address[] assets;
    }

    modifier isVaultManager {
        checkVaultManagers();
        _;
    }

    function checkVaultManagers() internal {
        require(msg.sender == vault.governance() || msg.sender == vault.management());
    }

    uint256 internal constant max = type(uint256).max;

    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips
    uint256 public maxSingleDeposit;
    uint256 public minDepositPeriod; // seconds
    uint256 public lastDepositTime;
    uint256 internal constant basisOne = 10000;
    bool internal isOriginal = true;

    constructor(
        address _vault,
        address _balancerVault,
        address _balancerPool,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod)
    public BaseStrategy(_vault){
        _initializeStrat(_vault, _balancerVault, _balancerPool, _maxSlippageIn, _maxSlippageOut, _maxSingleDeposit, _minDepositPeriod);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _balancerVault,
        address _balancerPool,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_vault, _balancerVault, _balancerPool, _maxSlippageIn, _maxSlippageOut, _maxSingleDeposit, _minDepositPeriod);
    }

    function _initializeStrat(
        address _vault,
        address _balancerVault,
        address _balancerBoostedPool,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod)
    internal {
        // health.ychad.eth
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);
        doSellRewards = true;
        bpt = IStablePhantomPool(_balancerBoostedPool);
        balancerPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(balancerPoolId);
        require(tokens.length > 0, "Empty Pool");
        uint8 numTokens = uint8(tokens.length);
        for (uint8 i = 0; i < numTokens; i++) {
            ILinearPool _lpt = ILinearPool(address(tokens[i]));
            if (address(_lpt) == address(bpt)) {
                // do nothing. This is just here so that _lpt.getMainToken doesn't revert from interface mismatch
            } else if (_lpt.getMainToken() == address(want)) {
                lpt = _lpt;
            }
        }
        require(address(lpt) != address(0x0), "token not supported in pool!");

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleDeposit = _maxSingleDeposit.mul(10 ** uint256(ERC20(address(want)).decimals()));
        minDepositPeriod = _minDepositPeriod;

        want.safeApprove(address(balancerVault), max);
    }

    event Cloned(address indexed clone);

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _balancerVault,
        address _balancerPool,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod
    ) external returns (address payable newStrategy) {
        require(isOriginal);

        bytes20 addressBytes = bytes20(address(this));

        assembly {
        // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(
            _vault, _strategist, _rewards, _keeper, _balancerVault, _balancerPool, _maxSlippageIn, _maxSlippageOut, _maxSingleDeposit, _minDepositPeriod
        );

        emit Cloned(newStrategy);
    }


    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("SSBv2 Boosted ", ERC20(address(want)).symbol(), " ", bpt.symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPooled());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        // 2 forms of profit. Incentivized rewards (BAL+other) and pool fees (want)
        collectTradingFees();
        // this would allow finer control over harvesting to get credits in without selling
        if (doSellRewards) {
            _sellRewards();
        }

        uint256 afterWant = balanceOfWant();

        _profit = afterWant.sub(beforeWant);
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _debtPayment = _debtPayment.add(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _debtPayment = _debtPayment.add(_profit);
            _profit = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now.sub(lastDepositTime) < minDepositPeriod) {
            return;
        }

        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());
        if (amountIn > 0) {
            _joinPool(amountIn);
            lastDepositTime = now;
        }
    }


    // withdraws will realize losses if the pool is in bad conditions. This will heavily rely on _enforceSlippage to revert
    // and make sure we don't have to realize losses when not necessary
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            uint256 toExitAmount = _amountNeeded.sub(looseAmount);

            _exitPool(tokensToBpts(toExitAmount));

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
        require(_amountNeeded == _liquidatedAmount.add(_loss), "!sanitycheck");
    }

    function liquidateAllPositions() internal override returns (uint256 liquidated) {
        _exitPool(balanceOfBpt());
        liquidated = balanceOfWant();
        return liquidated;
    }

    function prepareMigration(address _newStrategy) internal override {
        bpt.transfer(_newStrategy, balanceOfBpt());
        for (uint i = 0; i < rewardTokens.length; i++) {
            IERC20 token = rewardTokens[i];
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) {
                token.safeTransfer(_newStrategy, balance);
            }
        }
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view override returns (uint256){}

    function tendTrigger(uint256 callCostInWei) public view override returns (bool) {
        return now.sub(lastDepositTime) > minDepositPeriod && balanceOfWant() > 0;
    }

    // HELPERS //

    // swap from want --> lpt --> bpt
    function _joinPool(uint _wants) internal {
        _wants = Math.min(balanceOfWant(), _wants);
        uint prevBpts = balanceOfBpt();

        address[] memory assets = new address[](3);
        assets[0] = address(want);
        assets[1] = address(lpt);
        assets[2] = address(bpt);

        IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](2);
        steps[0] = IBalancerVault.BatchSwapStep(
            lpt.getPoolId(),
            0,
            1,
            _wants,
            abi.encode(0));
        steps[1] = IBalancerVault.BatchSwapStep(
            bpt.getPoolId(),
            1,
            2,
            0,
            abi.encode(0));

        int[] memory limits = new int[](3);
        limits[0] = int(_wants);

        balancerVault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN,
            steps,
            assets,
            IBalancerVault.FundManagement(address(this), false, address(this), false),
            limits,
            max);

        // price impact check
        uint estimatedBpts = tokensToBpts(_wants);
        uint investedBpts = balanceOfBpt().sub(prevBpts);
        require(
            investedBpts >= estimatedBpts ||
            estimatedBpts.sub(investedBpts).mul(basisOne).div(estimatedBpts) < maxSlippageIn, "slippedin!"
        );
    }

    function exitPool(uint _bpts) external isVaultManager {
        _exitPool(_bpts);
    }

    function _exitPool(uint _bpts) internal {
        _bpts = Math.min(balanceOfBpt(), _bpts);
        uint prevWants = balanceOfWant();
        uint prevEta = estimatedTotalAssets();

        address[] memory assets = new address[](3);
        assets[0] = address(bpt);
        assets[1] = address(lpt);
        assets[2] = address(want);

        IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](2);
        steps[0] = IBalancerVault.BatchSwapStep(
            bpt.getPoolId(),
            0,
            1,
            _bpts,
            abi.encode(0));
        steps[1] = IBalancerVault.BatchSwapStep(
            lpt.getPoolId(),
            1,
            2,
            0,
            abi.encode(0));

        int[] memory limits = new int[](3);
        limits[0] = int(_bpts);

        balancerVault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN,
            steps,
            assets,
            IBalancerVault.FundManagement(address(this), false, address(this), false),
            limits,
            max);

        // price impact check
        uint requestedWants = bptsToTokens(_bpts);
        uint exitedWants = balanceOfWant().sub(prevWants);

        // ensure that the exited wants didn't slip beyond threshold
        require(
            exitedWants >= requestedWants ||
            requestedWants.sub(exitedWants).mul(basisOne).div(requestedWants) < maxSlippageOut, "slippedout!"
        );
    }

    function sellRewards() external isVaultManager {
        _sellRewards();
    }

    function _sellRewards() internal {
        for (uint8 i = 0; i < rewardTokens.length; i++) {
            ERC20 rewardToken = ERC20(address(rewardTokens[i]));
            uint256 amount = rewardToken.balanceOf(address(this));

            uint decReward = rewardToken.decimals();
            uint decWant = ERC20(address(want)).decimals();

            if (amount > 10 ** (decReward > decWant ? decReward.sub(decWant) : 0)) {
                uint length = swapSteps[i].poolIds.length;
                IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](length);
                int[] memory limits = new int[](length + 1);
                limits[0] = int(amount);
                for (uint j = 0; j < length; j++) {
                    steps[j] = IBalancerVault.BatchSwapStep(swapSteps[i].poolIds[j],
                        j,
                        j + 1,
                        j == 0 ? amount : 0,
                        abi.encode(0)
                    );
                }
                balancerVault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN,
                    steps,
                    swapSteps[i].assets,
                    IBalancerVault.FundManagement(address(this), false, address(this), false),
                    limits,
                    now + 10);
            }
        }
    }

    function collectTradingFees() internal {
        uint256 total = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (total > debt) {
            uint256 profit = total.sub(debt);
            _exitPool(tokensToBpts(profit));
        }
    }

    function balanceOfWant() public view returns (uint256 _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfBpt() public view returns (uint256 _amount){
        return bpt.balanceOf(address(this));
    }

    function balanceOfReward(uint256 index) public view returns (uint256 _amount){
        return rewardTokens[index].balanceOf(address(this));
    }

    // returns an estimate of want tokens based on bpt balance
    function balanceOfPooled() public view returns (uint256 _amount){
        return bptsToTokens(balanceOfBpt());
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

    // for partnership rewards like Lido or airdrops
    function whitelistRewards(address _rewardToken, SwapSteps memory _steps) public isVaultManager {
        IERC20 token = IERC20(_rewardToken);
        token.approve(address(balancerVault), max);
        rewardTokens.push(token);
        swapSteps.push(_steps);
    }

    function delistAllRewards() public isVaultManager {
        for (uint i = 0; i < rewardTokens.length; i++) {
            rewardTokens[i].approve(address(balancerVault), 0);
        }
        IERC20[] memory noRewardTokens;
        rewardTokens = noRewardTokens;
        delete swapSteps;
    }

    function numRewards() public view returns (uint256 _num){
        return rewardTokens.length;
    }

    function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut, uint256 _maxSingleDeposit, uint256 _minDepositPeriod) public isVaultManager {
        require(_maxSlippageIn <= basisOne, "maxSlippageIn too high");
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne, "maxSlippageOut too high");
        maxSlippageOut = _maxSlippageOut;

        maxSingleDeposit = _maxSingleDeposit;
        minDepositPeriod = _minDepositPeriod;
    }

    function setDoSellRewards(bool _doSellRewards) external isVaultManager {
        doSellRewards = _doSellRewards;
    }

    function getSwapSteps() public view returns (SwapSteps[] memory){
        return swapSteps;
    }

    // Balancer requires this contract to be payable, so we add ability to sweep stuck ETH
    function sweepETH() public onlyGovernance {
        (bool success,) = governance().call{value : address(this).balance}("");
        require(success, "!FailedETHSweep");
    }

    receive() external payable {}
}
