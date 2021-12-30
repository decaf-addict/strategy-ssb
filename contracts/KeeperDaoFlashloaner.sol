// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
/// @dev This interfaces defines the functions of the KeeperDAO liquidity pool
/// that our contract needs to know about. The only function we need is the
/// borrow function, which allows us to take flash loans from the liquidity
/// pool.
interface LiquidityPool {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    /// @dev Borrow ETH/ERC20s from the liquidity pool. This function will (1)
    /// send an amount of tokens to the `msg.sender`, (2) call
    /// `msg.sender.call(_data)` from the KeeperDAO borrow proxy, and then (3)
    /// check that the balance of the liquidity pool is greater than it was
    /// before the borrow.
    ///
    /// @param _token The address of the ERC20 to be borrowed. ETH can be
    /// borrowed by specifying "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE".
    /// @param _amount The amount of the ERC20 (or ETH) to be borrowed. At least
    /// more than this amount must be returned to the liquidity pool before the
    /// end of the transaction, otherwise the transaction will revert.
    /// @param _data The calldata that encodes the callback to be called on the
    /// `msg.sender`. This is the mechanism through which the borrower is able
    /// to implement their custom keeper logic. The callback will be called from
    /// the KeeperDAO borrow proxy.
    function borrow(
        address _token,
        uint256 _amount,
        bytes calldata _data
    ) external;

    function borrower() external view returns (address);
}

interface IArber {
    function loanReceived(IERC20 _token, uint _loanAmount, uint _feeAmount) external;
}

/// @dev This contract implements a simple keeper. It borrows ETH from the
/// KeeperDAO liquidity pool, and immediately returns all of the borrowed ETH,
/// plus some amount of "profit" from its own balance. Instead of returning
/// profits from their own balances, keeper contracts will usually engage in
/// arbitrage or liquidations to earn profits that can be returned.
contract KeeperDaoFlashloaner is Ownable {
    IArber public arber;
    /// @dev Address of the KeeperDAO borrow proxy. This will be the
    /// `msg.sender` for calls to the `helloCallback` function.
    address public borrowProxy;

    /// @dev Address of the KeeperDAO liquidity pool. This is will be the
    /// address to which the `helloCallback` function must return all bororwed
    /// assets (and all excess profits).
    address payable public liquidityPool;

    /// @dev This modifier restricts the caller of a function to the KeeperDAO
    /// borrow proxy.
    modifier onlyBorrowProxy {
        if (msg.sender == borrowProxy) {
            _;
        }
    }

    constructor(address payable _liquidityPool, address _arber) public {
        liquidityPool = _liquidityPool;
        borrowProxy = LiquidityPool(liquidityPool).borrower();
        arber = IArber(_arber);
    }

    receive() external payable {}


    /// @dev Set the borrow proxy expected by this contract. This function can
    /// only be called by the current owner.
    ///
    /// @param _newBorrowProxy The new borrow proxy expected by this contract.
    function setBorrowProxy(address _newBorrowProxy) external onlyOwner {
        borrowProxy = _newBorrowProxy;
    }

    /// @dev Set the liquidity pool used by this contract. This function can
    /// only be called by the current owner.
    ///
    /// @param _newLiquidityPool The new liquidity pool used by this contract.
    /// It must be a payable address, because this contract needs to be able to
    /// return borrowed assets and profits to the liquidty pool.
    function setLiquidityPool(address payable _newLiquidityPool) external onlyOwner {
        liquidityPool = _newLiquidityPool;
        borrowProxy = LiquidityPool(liquidityPool).borrower();

    }

    /// @dev This function is the entry point of this keeper. An off-chain bot
    /// will call this function whenever it decides that it wants to borrow from
    /// this KeeperDAO liquidity pool. This function is similar to what you
    /// would expect in a "real" keeper implementation: it accepts paramters
    /// telling it what / how much to borrow, and which callback on this
    /// contract should be called once the borrowed funds have been transferred.
    function flashloan(address _token, uint _amountToBorrow) external {
        // The liquidity pool is guarded from re-entrance, so we can only call
        // this function once per transaction.
        LiquidityPool(liquidityPool).borrow(
            _token,
            _amountToBorrow,
            abi.encodeWithSelector(
                this.flashloanCallback.selector,
                IERC20(_token),
                _amountToBorrow,
                msg.sender
            )
        );
    }

    /// @dev This is the callback function that implements our custom keeper
    /// logic. We do not need to call this function directly; it will be called
    /// by the KeeperDAO borrow proxy when we call borrow on the KeeperDAO
    /// liquidity pool. In fact, usually, this function should be restricted so
    /// that is can only be called by the KeeperDAO borrow proxy.
    ///
    /// Just before this callback is called by the KeeperDAO borrow proxy, all
    /// of the assets that we want to borrow will be transferred to this
    /// contract. In this callback, we can do whatever we want with these
    /// assets; we can arbitrage between DEXs, liquidity positions on Compound,
    /// and so on. The only requirement is that at least more than the borrowed
    /// assets is returned.
    ///
    /// For example, imagine that we wanted borrowed 1 ETH. Before this callback
    /// is called, the KeeperDAO liquidity pool will have transferred 1 ETH to
    /// this contract. This callback can then do whatever it wants with that ETH.
    /// However, before the callback returns, it must return at least more than
    /// 1 ETH to the KeeperDAO liquidity pool (even if it is only returning
    /// 1 ETH + 1 WEI).
    ///
    /// In our example, we will not implement a complicated keeper strategy. We
    /// will simply return all of the borrowed ETH, plus a non-zero amount of
    /// profit. The amount of profit is explicitly specified by the owner of
    /// this contract when they initiate the borrow. Of course, this strategy
    /// does not generate profit by interacting with other protocols (like most
    /// keepers do). Instead, it just uses its own balance to return profits to
    /// KeeperDAO.
    function flashloanCallback(
        IERC20 _token,
        uint256 _amountBorrowed,
        address _initiator
    ) external onlyBorrowProxy {
        _token.transfer(_initiator, _amountBorrowed);
        arber.loanReceived(_token, _amountBorrowed, 1);
        uint returnAmount = _amountBorrowed + 1;
        _token.transferFrom(_initiator, address(this), returnAmount);
        require(_token.balanceOf(address(this)) >= returnAmount);

        // Notice that assets are transferred back to the liquidity pool, not to
        // the borrow proxy.
        _token.transfer(liquidityPool, returnAmount);
    }


    function setArber(address _arber) public onlyOwner {
        arber = IArber(_arber);
    }
}