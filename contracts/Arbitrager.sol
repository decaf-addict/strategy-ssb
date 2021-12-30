// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/BalancerV2.sol";
import "../interfaces/Flashloaner.sol";

interface WrappedToken is IERC20 {
    function deposit(address _to, uint _amount, uint16 _refCode, bool _fromUnderlying) external;

    function withdraw(address _to, uint _amount, bool _toUnderlying) external;
}

interface Decimals {
    function decimals() external view returns (uint);
}

contract Arbitrager is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IFlashloaner public loaner;
    ILinearPool public bbPool;
    IBalancerVault.FundManagement internal funds = IBalancerVault.FundManagement(address(this), false, address(this), false);

    constructor() public {}

    function setFlashloaner(address _address) external onlyOwner {
        loaner = IFlashloaner(_address);
    }

    function calculateArb(ILinearPool _bbPool) public view returns (uint _amount, bool _over){
        IBalancerVault vault = IBalancerVault(_bbPool.getVault());
        (,uint[] memory balances,) = vault.getPoolTokens(_bbPool.getPoolId());
        uint mainBalance = balances[_bbPool.getMainIndex()];
        (uint lower, uint upper) = _bbPool.getTargets();
        uint dec = Decimals(_bbPool.getMainToken()).decimals();

        // scale to decimals of the token, could lose precision
        if (dec < 18) {
            lower = lower.div(10 ** (18 - dec));
            upper = upper.div(10 ** (18 - dec));
        } else {
            lower = lower.mul(10 ** (dec - 18));
            upper = upper.mul(10 ** (dec - 18));
        }

        if (mainBalance > upper) {
            _amount = mainBalance.sub(upper);
        } else if (mainBalance < lower) {
            _amount = lower.sub(mainBalance);
        }

        return (_amount, mainBalance > upper);
    }

    function initiateArb(ILinearPool _bbPool) external onlyOwner {
        (uint loanAmount,) = calculateArb(_bbPool);
        if (loanAmount > 0) {
            bbPool = _bbPool;
            loaner.flashloan(IERC20(_bbPool.getMainToken()), loanAmount);
        }else{
            revert("nothing to arb");
        }
    }

    function loanReceived(IERC20 _token, uint _loanAmount, uint _feeAmount) external {
        require(msg.sender == address(loaner));
        IBalancerVault bVault = IBalancerVault(bbPool.getVault());
        WrappedToken wToken = WrappedToken(bbPool.getWrappedToken());
        (uint amount, bool over) = calculateArb(bbPool);

        if (amount == 0) {
            revert("nothing to arb");
        }

        uint tokenBalance = _token.balanceOf(address(this));

        if (over) {
            // wrap all tokens
            _token.approve(address(wToken), 0);
            _token.approve(address(wToken), tokenBalance);
            wToken.deposit(address(this), tokenBalance, 0, true);

            // trade wrapped token for token
            uint wTokenBalance = wToken.balanceOf(address(this));
            wToken.approve(address(bVault), 0);
            wToken.approve(address(bVault), wTokenBalance);
            IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
                bbPool.getPoolId(),
                IBalancerVault.SwapKind.GIVEN_OUT,
                address(wToken),
                address(_token),
                amount,
                abi.encode(0));
            bVault.swap(singleSwap, funds, wTokenBalance, 2 ** 256 - 1);
        } else {
            _token.approve(address(bVault), 0);
            _token.approve(address(bVault), tokenBalance);
            IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
                bbPool.getPoolId(),
                IBalancerVault.SwapKind.GIVEN_IN,
                address(_token),
                address(wToken),
                amount,
                abi.encode(0));
            bVault.swap(singleSwap, funds, wToken.balanceOf(address(this)), 2 ** 256 - 1);
        }
        wToken.withdraw(address(this), wToken.balanceOf(address(this)), true);
        _token.approve(address(loaner), 0);
        _token.approve(address(loaner), _loanAmount * 1001 / 1000);
        require(_token.balanceOf(address(this)) >= _loanAmount.add(_feeAmount));
    }


    function sweep(IERC20 _token, address _to) external onlyOwner {
        uint amount = _token.balanceOf(address(this));
        _token.approve(_to, 0);
        _token.approve(_to, amount);
        _token.transfer(_to, amount);
    }

    receive() external payable {}
}