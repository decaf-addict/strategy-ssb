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
    IBalancerPool public bpt;

    // @dev linear pool token. Primary linear pool that the strategy interacts with to wrap/unwrap want token
    ILinearPool public lpt;
    IERC20[] public rewardTokens;
    IAsset[] internal assets;
    SwapSteps[] internal swapSteps;
    uint256[] internal minAmountsOut;

    bytes32 public balancerPoolId;
    uint8 public numTokens;
    uint8 public tokenIndex;

    struct SwapSteps {
        bytes32[] poolIds;
        IAsset[] assets;
    }

    uint256 internal constant max = type(uint256).max;
    uint256 public maxSlippageIn;
    uint256 public maxSlippageOut;
    uint256 public maxSingleDeposit;
    uint256 public minDepositPeriod;
    uint256 public lastDepositTime;
    uint256 internal constant basisOne = 10000;
    bool internal isOriginal = true;
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
        // health.ychad.eth
        bpt = IBalancerPool(_balancerPool);
        balancerPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(balancerPoolId);
        numTokens = uint8(tokens.length);
        tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < numTokens; i++) {
            ILinearPool _lPool = ILinearPool(tokens[i]);
            if (_lPool.getMainToken() == address(want)) {
                tokenIndex = i;
                lpt = _lPool;
            }
        }
        require(tokenIndex != type(uint8).max, "token not supported in pool!");

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
        collectTradingFees(toCollect);
        sellRewards();

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

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now - lastDepositTime < minDepositPeriod) {
            revert();
        }

        uint256 pooledBefore = balanceOfPooled();
        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());

        if (amountIn > 0) {
            _enterPool(amountIn);

            uint256 pooledDelta = balanceOfPooled().sub(pooledBefore);
            uint256 joinSlipped = amountIn > pooledDelta ? amountIn.sub(pooledDelta) : 0;
            uint256 maxLoss = amountIn.mul(maxSlippageIn).div(basisOne);

            require(joinSlipped <= maxLoss, "Exceeded maxSlippageIn!");
            lastDepositTime = now;
        }
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        if (estimateTotalAssets() < _amountNeeded) {
            _liquidatedAmount = liquidateAllPositions();
            return (_liquidatedAmount, _amountNeeded.sub(_liquidatedAmount));
        }

        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            uint256 toExitAmount = _amountNeeded.sub(looseAmount);

            _exitPool(toExitAmount);

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
        if (bpts > 0) {
            _exitPoolAll();
        }

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
    function sellRewards() internal {
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

    function collectTradingFees(uint _profit) internal {
        if (_profit > 0) {
            _exitPool(_profit);
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

    function balanceOfPooled() public returns (uint256 _amount){
        uint256 totalWantPooled;
        uint bpts = balanceOfBpt();
        if (bpts > 0) {
            (IERC20[] memory tokens,uint256[] memory totalBalances,uint256 lastChangeBlock) = balancerVault.getPoolTokens(balancerPoolId);
            for (uint8 i = 0; i < numTokens; i++) {
                uint256 tokenPooled = totalBalances[i].mul(bpts).div(bpt.totalSupply());

                if (tokenPooled > 0) {
                    if (tokens[i] != want) {
                        // single step bc doing one swap within own pool i.e. wsteth -> weth
                        IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](1);
                        steps[0] = IBalancerVault.BatchSwapStep(balancerPoolId,
                            tokenIndex == 0 ? 1 : 0,
                            tokenIndex,
                            tokenPooled,
                            abi.encode(0)
                        );

                        // 2 assets of the pool, ordered by trade direction i.e. wsteth -> weth
                        IAsset[] memory path = new IAsset[](2);
                        path[0] = IAsset(address(tokenIndex == 0 ? tokens[1] : tokens[0]));
                        path[1] = IAsset(address(want));

                        tokenPooled = uint(- balancerVault.queryBatchSwap(IBalancerVault.SwapKind.GIVEN_IN,
                            steps,
                            path,
                            IBalancerVault.FundManagement(address(this), false, address(this), false))[1]);
                    }
                    totalWantPooled += tokenPooled;
                }
            }
        }
        return totalWantPooled;
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

    // request exact out
    function _exitPoolAll() internal {
        uint bpts = balanceOfBpt();
        address[] memory assets = new address[](3);
        assets[0] = address(bpt);
        assets[1] = address(lpt);
        assets[2] = address(want);

        IBalancerVault.BatchSwapStep[] steps = new IBalancerVault.BatchSwapStep[](2);
        steps[0] = IBalancerVault.BatchSwapStep(bpt.getPoolId(), 0, 1, bpts, abi.encode(0));
        steps[1] = IBalancerVault.BatchSwapStep(lpt.getPoolId(), 1, 2, 0, abi.encode(0));

        int[] limits = new int[](3);
        limits[0] = bpts;

        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            steps,
            assets,
            funds,
            limits,
            max
        );
    }
    // request exact out
    function _exitPool(uint256 _amountTokenOut) internal {
        address[] memory assets = new address[](3);
        assets[0] = address(bpt);
        assets[1] = address(lpt);
        assets[2] = address(want);

        IBalancerVault.BatchSwapStep[] steps = new IBalancerVault.BatchSwapStep[](2);
        steps[0] = IBalancerVault.BatchSwapStep(bpt.getPoolId(), 0, 1, 0, abi.encode(0));
        steps[1] = IBalancerVault.BatchSwapStep(lpt.getPoolId(), 1, 2, _amountTokenOut, abi.encode(0));

        int[] limits = new int[](3);
        limits[0] = balanceOfBpt();

        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_OUT,
            steps,
            assets,
            funds,
            limits,
            max
        );
    }

    // swap want for lpt, lpt for bpt
    function _enterPool(uint _amountTokenIn) internal {
        address[] memory assets = new address[](3);
        assets[0] = address(want);
        assets[1] = address(lpt);
        assets[2] = address(bpt);

        IBalancerVault.BatchSwapStep[] steps = new IBalancerVault.BatchSwapStep[](2);
        steps[0] = IBalancerVault.BatchSwapStep(lpt.getPoolId(), 0, 1, _amountTokenIn, abi.encode(0));
        steps[1] = IBalancerVault.BatchSwapStep(bpt.getPoolId(), 1, 2, 0, abi.encode(0));

        int[] limits = new int[](3);
        limits[0] = _amountTokenIn;

        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            steps,
            assets,
            funds,
            limits,
            max
        );
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
    // just in case there's positive slippage
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
