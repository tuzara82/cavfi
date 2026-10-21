// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IBLaunch {
    struct Launch {
        address creator; uint64 createdAt; bool graduated; uint256 vDoge; uint256 vTok; uint256 realDoge;
        uint256 tokensLeft; uint256 target; address pair; string name; string symbol; string description; string image;
    }
    function info(address) external view returns (Launch memory);
}
interface IBLimit {
    struct Order {
        address maker; uint64 expiry; uint8 status; bool nativeIn; bool nativeOut; address tokenIn; address tokenOut;
        uint256 amountIn; uint256 minOut; uint256 amountOut;
    }
    function get(uint256) external view returns (Order memory);
}
interface IBChef { function userInfo(uint256, address) external view returns (uint256 amount, uint256 rewardDebt); }
interface IBFactory { function getPair(address, address) external view returns (address); }
interface IBPair { function token0() external view returns (address); function token1() external view returns (address); function balanceOf(address) external view returns (uint256); }
interface IBVote { function locked(address) external view returns (uint256); function choicesOf(address) external view returns (uint256[] memory, uint256[] memory); }

/// @title CavFi Royal Court badges
/// @notice Soulbound (non-transferable) achievement badges, one of each per address, with the
///         artwork stored on-chain. Most are claimed by the holder and checked on-chain against
///         the CavFi contracts; "Royal Swapper" and "Top Ten" are handed out by the CavFi bot.
contract KingBadges is ERC1155, Ownable {
    using Strings for uint256;

    uint256 public constant SWAPPER = 1;
    uint256 public constant LAUNCHER = 2;
    uint256 public constant CREATOR = 3;
    uint256 public constant PATIENT = 4;
    uint256 public constant KEEPER = 5;
    uint256 public constant LIQUIDITY = 6;
    uint256 public constant VOTER = 7;
    uint256 public constant TOP_TEN = 8;
    uint256 public constant COUNT = 8;

    string public constant name = "CavFi Royal Court";
    string public constant symbol = "COURT";

    address public minter;
    address public launch;
    address public limit;
    address public farm;
    address public stake;
    address public factory;
    address public vote;
    mapping(uint256 => uint256) public holders;

    event Earned(address indexed who, uint256 indexed id);

    constructor(address _owner, address _minter) ERC1155("") Ownable(_owner) { minter = _minter; }

    function setMinter(address m) external onlyOwner { minter = m; }

    function setSources(address _launch, address _limit, address _farm, address _stake, address _factory, address _vote) external onlyOwner {
        (launch, limit, farm, stake, factory, vote) = (_launch, _limit, _farm, _stake, _factory, _vote);
    }

    // ------------------------------------------------------------------ claims
    function claimLauncher(address token) external {
        require(launch != address(0) && IBLaunch(launch).info(token).creator == msg.sender, "Badges: not your launch");
        _give(msg.sender, LAUNCHER);
    }

    function claimCreator(address token) external {
        IBLaunch.Launch memory L = IBLaunch(launch).info(token);
        require(L.creator == msg.sender && L.graduated, "Badges: your token has not graduated");
        _give(msg.sender, CREATOR);
    }

    function claimPatient(uint256 orderId) external {
        IBLimit.Order memory o = IBLimit(limit).get(orderId);
        require(o.maker == msg.sender && o.status == 2, "Badges: no filled order of yours");
        _give(msg.sender, PATIENT);
    }

    function claimKeeper(bool fromStake, uint256 pid) external {
        (uint256 amt, ) = IBChef(fromStake ? stake : farm).userInfo(pid, msg.sender);
        require(amt > 0, "Badges: nothing staked there");
        _give(msg.sender, KEEPER);
    }

    function claimLiquidity(address pair) external {
        require(factory != address(0) && IBFactory(factory).getPair(IBPair(pair).token0(), IBPair(pair).token1()) == pair, "Badges: not a CavFi pool");
        require(IBPair(pair).balanceOf(msg.sender) > 0, "Badges: no LP in that pool");
        _give(msg.sender, LIQUIDITY);
    }

    function claimVoter() external {
        (uint256[] memory pids, ) = IBVote(vote).choicesOf(msg.sender);
        require(IBVote(vote).locked(msg.sender) > 0 && pids.length > 0, "Badges: lock KingS and vote first");
        _give(msg.sender, VOTER);
    }

    /// @notice Bot-awarded badges (Royal Swapper, Top Ten). Already owned: skipped, not reverted.
    function award(address[] calldata to, uint256 id) external {
        require(msg.sender == minter || msg.sender == owner(), "Badges: not minter");
        require(id == SWAPPER || id == TOP_TEN, "Badges: claim this one yourself");
        for (uint256 i; i < to.length; i++) if (balanceOf(to[i], id) == 0) _give(to[i], id);
    }

    function _give(address to, uint256 id) internal {
        require(balanceOf(to, id) == 0, "Badges: already yours");
        holders[id]++;
        _mint(to, id, 1, "");
        emit Earned(to, id);
    }

    /// @notice Which badges an address holds, as a bitmask (bit id-1).
    function badgesOf(address who) external view returns (uint256 mask) {
        for (uint256 id = 1; id <= COUNT; id++) if (balanceOf(who, id) > 0) mask |= 1 << (id - 1);
    }

    // soulbound: only minting
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        require(from == address(0), "Badges: soulbound");
        super._update(from, to, ids, values);
    }

    function setApprovalForAll(address, bool) public pure override { revert("Badges: soulbound"); }

    // ------------------------------------------------------------------ on-chain art
    function _meta(uint256 id) internal pure returns (string memory title, string memory desc, string memory color, string memory mark) {
        if (id == SWAPPER) return ("Royal Swapper", "Made a swap on CavFi.", "#A3461E", "M22 25h20l-5-5M42 39H22l5 5");
        if (id == LAUNCHER) return ("Pup Launcher", "Launched a meme token on the CavFi launchpad.", "#7A3FA8", "M32 16c6 5 8 12 8 18l-8 8-8-8c0-6 2-13 8-18z");
        if (id == CREATOR) return ("Crowned Creator", "A token you launched filled its curve and graduated.", "#C9961A", "M20 40l3-16 9 8 9-8 3 16z");
        if (id == PATIENT) return ("Patient Pup", "A limit order of yours was filled.", "#1E5FA8", "M32 18a14 14 0 1 0 .1 0zM32 24v9l6 4");
        if (id == KEEPER) return ("Kennel Keeper", "Staked tokens or LP to earn KingS.", "#1F7A4D", "M18 34l14-12 14 12v12H18z");
        if (id == LIQUIDITY) return ("Liquidity Lord", "Provides liquidity to a CavFi pool.", "#1B7A8A", "M32 16s10 11 10 18a10 10 0 0 1-20 0c0-7 10-18 10-18z");
        if (id == VOTER) return ("Court Voter", "Locked KingS and voted on farm rewards.", "#8A5A1E", "M20 30l8 8 16-16");
        if (id == TOP_TEN) return ("Top Ten", "Finished a week in the top 10 of the CavFi leaderboard.", "#B3261E", "M32 16l4.7 9.6 10.6 1.5-7.7 7.5 1.8 10.5L32 40l-9.4 5.1 1.8-10.5-7.7-7.5 10.6-1.5z");
        revert("Badges: unknown id");
    }

    function svg(uint256 id) public pure returns (string memory) {
        (string memory title, , string memory color, string memory mark) = _meta(id);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 80">',
            '<circle cx="32" cy="32" r="30" fill="', color, '"/><circle cx="32" cy="32" r="25" fill="none" stroke="#FFF8EE" stroke-opacity=".5" stroke-width="1.5"/>',
            '<path d="', mark, '" fill="none" stroke="#FFF8EE" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>',
            '<path d="M24 10l2.5-6 3.5 4 2-5 2 5 3.5-4 2.5 6z" fill="#E7B73C"/>',
            '<text x="32" y="74" text-anchor="middle" font-family="Georgia,serif" font-size="7.5" fill="#1B1A2E">', title, '</text></svg>'
        );
    }

    function uri(uint256 id) public pure override returns (string memory) {
        (string memory title, string memory desc, , ) = _meta(id);
        string memory json = string.concat(
            '{"name":"CavFi \\u00b7 ', title, '","description":"', desc, ' Soulbound CavFi Royal Court badge #', id.toString(),
            '.","image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg(id))), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
