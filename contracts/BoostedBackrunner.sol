// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/IERC3156FlashLender.sol";
import "../interfaces/IERC3156FlashBorrower.sol";


interface IRebalancer {
    function getSwapAndAmountInNeeded(address _pool, uint256 _desiredBalance)
    external view returns (IBalancerVault.SingleSwap memory _swap, uint256 _amountInNeededForSwap);
}

interface WrappedToken is IERC20 {
    function deposit(address _to, uint _amount, uint16 _refCode, bool _fromUnderlying) external;

    function withdraw(address _to, uint _amount, bool _toUnderlying) external;
}

interface Decimals {
    function decimals() external returns (uint);
}

contract BoostedBackrunner is IERC3156FlashBorrower, Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum Action {NORMAL, OTHER}
    IERC20 internal constant dai = IERC20(address(0x6B175474E89094C44Da98b954EedeAC495271d0F));
    bytes32 internal constant stablePoolId = 0x06df3b2bbb68adc8b0e302443692037ed9f91b42000000000000000000000063;
    IERC3156FlashLender internal lender;
    IRebalancer internal rebalancer;
    IBalancerVault internal bVault;
    IERC20[] internal allPools;
    IBalancerVault.FundManagement internal funds = IBalancerVault.FundManagement(address(this), false, address(this), false);
    ILinearPool[] internal profitablePools;

    constructor(address _bVault, address _boostedPool, address _rebalancer, address _lender) public {
        rebalancer = IRebalancer(_rebalancer);
        bVault = IBalancerVault(_bVault);
        lender = IERC3156FlashLender(_lender);
        (IERC20[] memory pools,,) = bVault.getPoolTokens(IBalancerPool(_boostedPool).getPoolId());
        for (uint i = 0; i < pools.length; i++) {
            if (address(pools[i]) != _boostedPool) {
                allPools.push(pools[i]);
            }
        }
    }

    function _estimateProfit(ILinearPool _pool) internal view returns (uint _gain, IBalancerVault.SingleSwap memory _swap, address _loanToken, uint _amountMainRequired){
        // if there's no opportunities, the rebalancer call will revert
        (IBalancerVault.SingleSwap memory singleSwap, uint amountNeededIn) = rebalancer.getSwapAndAmountInNeeded(address(_pool), 0);
        _swap = singleSwap;
        if (singleSwap.kind == IBalancerVault.SwapKind.GIVEN_OUT) {
            _amountMainRequired = amountNeededIn * _pool.getWrappedTokenRate() / 1e18;
            _gain = singleSwap.amount - _amountMainRequired;
            _loanToken = address(singleSwap.assetOut);
        } else {
            revert("unsupported given in");
        }

        return (_gain, _swap, _loanToken, _amountMainRequired);
    }

    //  @param pools: select only profitable ones
    function run(uint _minProfitUsd) external onlyOwner {
        uint amountNeeded;
        for (uint i = 0; i < allPools.length; i++) {
            ILinearPool pool = ILinearPool(address(allPools[i]));
            (,uint[] memory balances,) = bVault.getPoolTokens(pool.getPoolId());
            uint dec = Decimals(pool.getMainToken()).decimals();
            (,uint upperTarget) = pool.getTargets();
            if (balances[pool.getMainIndex()].mul(10 ** (18 - dec)) > upperTarget) {
                (uint gain,,, uint amountMainRequired) = _estimateProfit(pool);
                if (gain.mul(10 ** (18 - dec)) > _minProfitUsd) {
                    profitablePools.push(pool);
                    amountNeeded += amountMainRequired.mul(10 ** (18 - dec));
                }
            }
        }

        if (amountNeeded > 0) {
            // add some buffer for trading fees
            amountNeeded = amountNeeded * 101 / 100;
            dai.approve(address(lender), 0);
            dai.approve(address(lender), amountNeeded);
            flashBorrow(address(dai), amountNeeded);
        }
    }

    /// @dev Initiate a flash loan
    function flashBorrow(
        address token,
        uint256 amount
    ) internal {
        bytes memory data = abi.encode(Action.NORMAL);
        lender.flashLoan(this, token, amount, data);
    }

    /// @dev ERC-3156 Flash loan callback
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(fee == 0, "not free");
        require(msg.sender == address(lender), "FlashBorrower: Untrusted lender");
        require(initiator == address(this), "FlashBorrower: Untrusted loan initiator");

        (Action action) = abi.decode(data, (Action));
        if (action == Action.NORMAL) {
            require(IERC20(token).balanceOf(address(this)) >= amount);

            // dai to required tokens
            _arb();
        }
        delete profitablePools;
        require(dai.balanceOf(address(this)) > amount, "no profit");
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }


    // dai to main (swap1)
    // main to wrapped
    // wrapped for main arb (swap2)
    // main to dai (swap3)
    function _arb() internal {
        for (uint i = 0; i < profitablePools.length; i++) {
            ILinearPool pool = ILinearPool(address(profitablePools[i]));
            (uint gain, IBalancerVault.SingleSwap memory swap2, address loanToken, uint amountMainRequired) = _estimateProfit(pool);

            IERC20 main = IERC20(pool.getMainToken());
            WrappedToken wrapped = WrappedToken(pool.getWrappedToken());

            dai.approve(address(bVault), type(uint256).max);
            wrapped.approve(address(bVault), type(uint256).max);

            // dai to main (swap1)
            if (main != dai) {
                main.approve(address(bVault), type(uint256).max);
                IBalancerVault.SingleSwap memory swap1 = IBalancerVault.SingleSwap(
                    stablePoolId,
                    IBalancerVault.SwapKind.GIVEN_OUT,
                    address(dai),
                    address(main),
                    amountMainRequired,
                    abi.encode(0)
                );
                bVault.swap(
                    swap1,
                    funds,
                    dai.balanceOf(address(this)),
                    2 ** 256 - 1);
            }

            // main to wrapped
            main.approve(address(wrapped), type(uint256).max);
            wrapped.deposit(address(this), main.balanceOf(address(this)), 0, true);

            // wrapped for main arb (swap2)
            bVault.swap(
                swap2,
                funds,
                wrapped.balanceOf(address(this)),
                2 ** 256 - 1);

            // main to dai (swap3)
            if (main != dai) {
                IBalancerVault.SingleSwap memory swap3 = IBalancerVault.SingleSwap(
                    stablePoolId,
                    IBalancerVault.SwapKind.GIVEN_IN,
                    address(main),
                    address(dai),
                    main.balanceOf(address(this)),
                    abi.encode(0)
                );
                bVault.swap(
                    swap3,
                    funds,
                    0,
                    2 ** 256 - 1);
            }

            dai.approve(address(bVault), 0);
            wrapped.approve(address(bVault), 0);
            main.approve(address(bVault), 0);
        }
    }

    function sweep() external onlyOwner {
        dai.transfer(owner(), dai.balanceOf(address(this)));
    }

    receive() external payable {}
}