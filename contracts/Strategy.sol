// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";

interface IName {
    function name() external view returns (string memory);
}

/// @dev This strategy is implemented specifically for the balancer boosted pools. A boosted pool is a metapool with each of its pool
/// tokens being other bpts.
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 internal constant weth = IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IBalancerVault public balancerVault;

    /// @dev boosted pool token. Primary pool that the linear pool integrates into. For boosted pools, bpt is preminted. Instead of joining/exiting
    /// pool with want, we have to swap for it.
    IStablePhantomPool public bpt;

    // @dev linear pool token. Primary linear pool that the strategy interacts with to wrap/unwrap want token
    ILinearPool public lpt;
    IERC20[] public rewardTokens;
    IAsset[] internal assets;
    SwapSteps[] internal swapSteps;
    uint256[] internal minAmountsOut;

    bytes32 public boostedPoolId;
    uint8 public numTokens;
    uint8 public tokenIndex;
    uint8 public bptIndex;

    struct SwapSteps {
        bytes32[] poolIds;
        address[] assets;
    }

    uint256 internal constant max = type(uint256).max;
    uint256 public maxSlippageIn;
    uint256 public maxSlippageOut;
    uint256 public maxSingleDeposit;
    uint256 public minDepositPeriod;
    uint256 public lastDepositTime;
    uint256 internal constant basisOne = 10000;
    uint internal etaCached;

    IBalancerVault.FundManagement funds = IBalancerVault.FundManagement(address(this), false, address(this), false);

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
        address _balancerPool,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod)
    internal {
        require(address(bpt) == address(0x0), "Strategy already initialized!");
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);
        bpt = IStablePhantomPool(_balancerPool);
        boostedPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(boostedPoolId);
        numTokens = uint8(tokens.length);
        tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < numTokens; i++) {
            ILinearPool _lpt = ILinearPool(address(tokens[i]));
            if (address(_lpt) == address(bpt)) {
                bptIndex = i;
            } else if (_lpt.getMainToken() == address(want)) {
                tokenIndex = i;
                lpt = _lpt;
            }
        }
        require(tokenIndex != type(uint8).max, "token not supported in pool!");

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleDeposit = _maxSingleDeposit.mul(10 ** uint256(ERC20(address(want)).decimals()));
        minDepositPeriod = _minDepositPeriod;

        want.safeApprove(address(balancerVault), max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return string(abi.encodePacked("SingleSidedBalancer ", bpt.symbol(), "Pool ", ERC20(address(want)).symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return etaCached;
    }

    // There is no way to calculate the total asset without doing a tx call.
    function estimateTotalAssets() public returns (uint256 _wants) {
        etaCached = balanceOfWant().add(balanceOfPooled());
        return etaCached;
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        uint256 total = estimateTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint toCollect = total > debt ? total.sub(debt) : 0;

        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        // 2 forms of profit. Incentivized rewards (BAL+other) and pool fees (want)
        _collectTradingFees(toCollect);
        _sellRewards();

        uint256 afterWant = balanceOfWant();

        _profit = afterWant.sub(beforeWant);
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
    }

    event Debug(string msg, uint value);

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now - lastDepositTime < minDepositPeriod) {
            return;
        }

        uint256 pooledBefore = balanceOfPooled();
        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());

        if (amountIn > 0) {
            _swap(amountIn, IBalancerVault.SwapKind.GIVEN_IN, address(want), lpt, address(bpt), bpt, false);

            uint256 pooledDelta = balanceOfPooled().sub(pooledBefore);
            uint256 joinSlipped = amountIn > pooledDelta ? amountIn.sub(pooledDelta) : 0;
            uint256 maxLoss = amountIn.mul(maxSlippageIn).div(basisOne);

            require(joinSlipped <= maxLoss, "Exceeded maxSlippageIn!");
            lastDepositTime = now;
        }
    }

    function liquidate(uint256 _amountNeeded) external returns (uint256 _liquidatedAmount, uint256 _loss){
        return liquidatePosition(_amountNeeded);
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        emit Debug("_amountNeeded", _amountNeeded);
        uint estimate = estimateTotalAssets();
        emit Debug("estimate", estimate);
        if (estimate < _amountNeeded) {
            _liquidatedAmount = liquidateAllPositions();
            return (_liquidatedAmount, _amountNeeded.sub(_liquidatedAmount));
        }

        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            uint256 toExitAmount = _amountNeeded.sub(looseAmount);
            _swap(toExitAmount, IBalancerVault.SwapKind.GIVEN_OUT, address(want), lpt, address(bpt), bpt, false);

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);

            _enforceSlippageOut(toExitAmount, _liquidatedAmount.sub(looseAmount));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256 liquidated) {
        uint eta = estimateTotalAssets();
        uint256 bpts = balanceOfBpt();

        _swap(bpts, IBalancerVault.SwapKind.GIVEN_IN, address(bpt), bpt, address(want), lpt, false);

        liquidated = balanceOfWant();
        _enforceSlippageOut(eta, liquidated);
        return liquidated;
    }

    function prepareMigration(address _newStrategy) internal override {
        bpt.transfer(_newStrategy, balanceOfBpt());
        for (uint i = 0; i < rewardTokens.length; i++) {
            IERC20 token = rewardTokens[i];
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) {
                token.transfer(_newStrategy, balance);
            }
        }
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view override returns (uint256){}

    function tendTrigger(uint256 callCostInWei) public view override returns (bool) {
        return now.sub(lastDepositTime) > minDepositPeriod && balanceOfWant() > 0;
    }

    function harvestTrigger(uint256 callCostInWei) public view override returns (bool){
        bool hasRewards;
        for (uint8 i = 0; i < rewardTokens.length; i++) {
            ERC20 rewardToken = ERC20(address(rewardTokens[i]));

            uint decReward = rewardToken.decimals();
            uint decWant = ERC20(address(want)).decimals();
            if (rewardToken.balanceOf(address(this)) > 10 ** (decReward > decWant ? decReward.sub(decWant) : 0)) {
                hasRewards = true;
                break;
            }
        }
        return super.harvestTrigger(callCostInWei) && hasRewards;
    }


    // HELPERS //
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
                    funds,
                    limits,
                    now + 10);
            }
        }
    }

    function _collectTradingFees(uint _profit) internal {
        _swap(_profit, IBalancerVault.SwapKind.GIVEN_OUT, address(bpt), bpt, address(want), lpt, false);

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

    function balanceOfPooled() public returns (uint256 _amount){
        uint256 totalWantPooled;
        uint bpts = balanceOfBpt();
        if (bpts > 0) {
            (IERC20[] memory tokens,uint256[] memory totalBalances,uint256 lastChangeBlock) = balancerVault.getPoolTokens(boostedPoolId);
            for (uint8 i = 0; i < numTokens; i++) {
                if (i == bptIndex) {
                    continue;
                }

                ILinearPool _lpt = ILinearPool(address(tokens[i]));
                uint decWant = ERC20(address(want)).decimals();
                uint decLpt = ERC20(address(_lpt)).decimals();
                uint256 lpts = totalBalances[i].mul(bpts).div(bpt.getVirtualSupply());
                int[] memory deltas = _swap(lpts, IBalancerVault.SwapKind.GIVEN_IN, address(_lpt), bpt, address(want), lpt, true);
                lpts = uint(- deltas[deltas.length - 1]);
                totalWantPooled += lpts;
            }
        }
        return totalWantPooled;
    }

    // Using a struct here to prevent stack too deep error
    struct StackHelper {
        uint8 assetsIndex;
        uint8 swapsIndex;
        bool isSame;
        bool givenIn;
    }


    // In swaps of the type given_in you're pushing a token into a pipeline and getting another one at the end.
    // At each step along the way, the output of a swap becomes input of the next.
    // @param _amount = amount sent to pool to trade
    //
    // In swaps of the type given_out you're pulling a token from a pipeline; the last step pulls some other token from your own account.
    // At each step along the way, the tokens that will go into a swap will be the ones that come out of the next.
    // @param _amount = amount desired to be returned by pool
    //
    function _swap(uint _amount, IBalancerVault.SwapKind _swapKind, address _swap1Token, IBalancerPool _swap1Pool, address _swap2Token, IBalancerPool _swap2Pool, bool _mock) internal returns (int256[] memory _changes){
        if (_amount > 0) {
            StackHelper memory sh;
            sh.isSame = _swap1Token == address(lpt);

            address[] memory assets = new address[](sh.isSame ? 2 : 3);
            assets[sh.assetsIndex] = _swap1Token;
            if (!sh.isSame) sh.assetsIndex++;
            assets[sh.assetsIndex] = address(lpt);
            sh.assetsIndex++;
            assets[sh.assetsIndex] = _swap2Token;

            sh.givenIn = _swapKind == IBalancerVault.SwapKind.GIVEN_IN;
            IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](sh.isSame ? 1 : 2);
            steps[sh.swapsIndex] = IBalancerVault.BatchSwapStep(
                _swap1Pool.getPoolId(),
                sh.givenIn ? sh.swapsIndex : sh.swapsIndex + 1,
                sh.givenIn ? sh.swapsIndex + 1 : sh.swapsIndex,
                _amount,
                abi.encode(0));
            if (!sh.isSame) sh.swapsIndex++;
            steps[sh.swapsIndex] = IBalancerVault.BatchSwapStep(_swap2Pool.getPoolId(),
                sh.givenIn ? sh.swapsIndex : sh.swapsIndex + 1,
                sh.givenIn ? sh.swapsIndex + 1 : sh.swapsIndex,
                sh.isSame ? _amount : 0,
                abi.encode(0));


            int[] memory limits = new int[](sh.isSame ? 2 : 3);
            limits[sh.givenIn ? 0 : 2] = int(sh.givenIn ? _amount : IERC20(_swap2Token).balanceOf(address(this)));

            return _mock
            ? balancerVault.queryBatchSwap(_swapKind, steps, assets, funds)
            : balancerVault.batchSwap(_swapKind, steps, assets, funds, limits, max);
        } else {
            return _changes;
        }
    }

    // for partnership rewards like Lido or airdrops
    function whitelistRewards(address _rewardToken, SwapSteps memory _steps) public onlyVaultManagers {
        IERC20 token = IERC20(_rewardToken);
        token.approve(address(balancerVault), max);
        rewardTokens.push(token);
        swapSteps.push(_steps);
    }

    function delistAllRewards() public onlyVaultManagers {
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

    /// @param _maxSlippageIn in bips
    /// @param _maxSlippageOut in bips
    /// @param _maxSingleDeposit decimal agnostic (enter 100 for 100 tokens)
    /// @param _minDepositPeriod in seconds
    function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut, uint256 _maxSingleDeposit, uint256 _minDepositPeriod) public onlyVaultManagers {
        require(_maxSlippageIn <= basisOne, "maxSlippageIn too high");
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne, "maxSlippageOut too high");
        maxSlippageOut = _maxSlippageOut;

        maxSingleDeposit = _maxSingleDeposit.mul(10 ** uint256(ERC20(address(want)).decimals()));
        minDepositPeriod = _minDepositPeriod;
    }

    // enforce that amount exited didn't slip beyond our tolerance
    function _enforceSlippageOut(uint _intended, uint _actual) internal {
        uint256 exitSlipped = _intended > _actual ? _intended.sub(_actual) : 0;
        uint256 maxLoss = _intended.mul(maxSlippageOut).div(basisOne);
        require(exitSlipped <= maxLoss, "Exceeded maxSlippageOut!");
    }

    function getSwapSteps() public view returns (SwapSteps[] memory){
        return swapSteps;
    }

    receive() external payable {}
}
