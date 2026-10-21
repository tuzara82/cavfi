// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Wrapped DOGE (WETH9-style) for KingSwap pools
contract WDOGE {
    string public constant name = "Wrapped DOGE";
    string public constant symbol = "WDOGE";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed to, uint256 value);
    event Withdrawal(address indexed from, uint256 value);

    receive() external payable { deposit(); }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "WDOGE: balance");
        balanceOf[msg.sender] -= wad;
        emit Withdrawal(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WDOGE: send");
    }

    function totalSupply() external view returns (uint256) { return address(this).balance; }

    function approve(address spender, uint256 wad) external returns (bool) {
        allowance[msg.sender][spender] = wad;
        emit Approval(msg.sender, spender, wad);
        return true;
    }

    function transfer(address to, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, to, wad);
    }

    function transferFrom(address from, address to, uint256 wad) public returns (bool) {
        require(balanceOf[from] >= wad, "WDOGE: balance");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= wad, "WDOGE: allowance");
            allowance[from][msg.sender] -= wad;
        }
        balanceOf[from] -= wad;
        balanceOf[to] += wad;
        emit Transfer(from, to, wad);
        return true;
    }
}
