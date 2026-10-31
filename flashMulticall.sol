// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

contract FlashMulticall is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal owner;
    IWETH internal _weth;
    IMorpho internal _morpho;

    mapping(address => bool) public whitelist;

    constructor(address weth, address morpho) payable {
        owner = msg.sender;
        _weth = IWETH(weth);
        _morpho = IMorpho(morpho); // 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb

        whitelist[owner] = true;
        // whitelist[] = true;
        // whitelist[] = true;
        // whitelist[] = true;

        _weth.deposit{value: msg.value}();
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    modifier onlyWhitelist() {
        require(whitelist[msg.sender], "Not in whitelist");
        _;
    }

    function rewhitelist(address newAddress) external onlyOwner {
        whitelist[newAddress] = true;
    }

    function dewhitelist(address oldAddress) external onlyOwner {
        whitelist[oldAddress] = false;
    }

    function withdraw(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }
	
    function flash_multicall(address token, uint256 amount, address[] memory _targets, bytes[] memory _payloads)
        external
        payable
        nonReentrant
        onlyWhitelist
    {
		// a basic tip strategy is to pay the builder with msg.value 
        // if (msg.value > 0) {
        //     payable(block.coinbase).transfer(msg.value);
        // }
        bytes memory data = abi.encode(_targets, _payloads, token);
        _morpho.flashLoan(token, amount, data);
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(_morpho), "Unauthorized");

        (address[] memory _targets, bytes[] memory _payloads, address token) =
            abi.decode(data, (address[], bytes[], address));

        for (uint256 i = 0; i < _targets.length;) {
            (bool _success, bytes memory _response) = _targets[i].call(_payloads[i]);
            require(_success);
            _response;

            unchecked { ++i; }
        }

        IERC20(token).approve(address(_morpho), assets);
    }

    //
    // generic mc
    //
    function multicall(address[] memory _targets, bytes[] memory _payloads)
        external
        nonReentrant
        onlyWhitelist
        returns (bool success)
    {
        for (uint256 i = 0; i < _targets.length;) {
            (bool _success, bytes memory _response) = _targets[i].call(_payloads[i]);
            require(_success);
            _response;

            unchecked { ++i; }
        }

        return true;
    }

	// single call

    function call(address payable _to, uint256 _value, bytes calldata _data)
        external
        payable
        nonReentrant
        onlyWhitelist
        returns (bytes memory)
    {
        require(_to != address(0));
        (bool _success, bytes memory _result) = _to.call{value: _value}(_data);
        require(_success);
        return _result;
    }

    function sweepETH() external onlyOwner {
        (bool success, ) = payable(owner).call{value: address(this).balance}("");
        require(success, "Sweep failed");
    }

    receive() external payable {
        _weth.deposit{value: msg.value}();
    }
}
