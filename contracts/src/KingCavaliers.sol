// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CavFi Cavaliers
/// @notice A generative NFT collection of crowned Cavalier King Charles Spaniels. Art and metadata
///         live fully on-chain. Holders can stake their Cavaliers (they stay in the wallet, locked)
///         to earn KingS; rarer Cavaliers carry more weight in the reward pool.
/// @dev Traits come from a pseudo-random seed taken at mint (prevrandao + blockhash). That is fine
///      for a testnet collection but is not manipulation-proof randomness.
contract KingCavaliers is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    IERC20 public immutable kings;
    uint256 public immutable maxSupply;
    uint256 public constant MAX_PER_TX = 5;

    uint256 public price;
    uint256 public totalMinted;
    address public feeTo;
    mapping(uint256 => uint256) public dna;

    // ---- staking (Synthetix-style, weighted) ----
    mapping(uint256 => bool) public staked;
    mapping(address => uint256) public weightOf;
    uint256 public totalWeight;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerWeightStored;
    mapping(address => uint256) public rewardPerWeightPaid;
    mapping(address => uint256) public rewards;

    event Minted(address indexed to, uint256 indexed id, uint256 dna);
    event Staked(address indexed user, uint256 indexed id, uint256 weight);
    event Unstaked(address indexed user, uint256 indexed id, uint256 weight);
    event Claimed(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount, uint256 duration);
    event PriceSet(uint256 price);
    event FeeToSet(address feeTo);

    error BadAmount();
    error SoldOut();
    error WrongPayment();
    error NotOwner(uint256 id);
    error AlreadyStaked(uint256 id);
    error NotStaked(uint256 id);
    error Locked(uint256 id);
    error BadDuration();
    error RateTooHigh();

    constructor(address owner_, IERC20 kings_, uint256 maxSupply_, uint256 price_) ERC721("CavFi Cavaliers", "CAVS") Ownable(owner_) {
        kings = kings_;
        maxSupply = maxSupply_;
        price = price_;
        feeTo = owner_;
    }

    // ------------------------------------------------------------------ mint

    function mint(uint256 n) external payable nonReentrant returns (uint256 firstId) {
        if (n == 0 || n > MAX_PER_TX) revert BadAmount();
        if (totalMinted + n > maxSupply) revert SoldOut();
        if (msg.value != price * n) revert WrongPayment();
        firstId = totalMinted + 1;
        for (uint256 i; i < n; i++) {
            uint256 id = firstId + i;
            uint256 d = uint256(keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), msg.sender, id, block.timestamp)));
            dna[id] = d;
            _mint(msg.sender, id);
            emit Minted(msg.sender, id, d);
        }
        totalMinted += n;
    }

    function setPrice(uint256 p) external onlyOwner {
        price = p;
        emit PriceSet(p);
    }

    function setFeeTo(address f) external onlyOwner {
        feeTo = f;
        emit FeeToSet(f);
    }

    /// Sends mint proceeds to feeTo.
    function withdraw() external {
        (bool ok,) = feeTo.call{value: address(this).balance}("");
        require(ok, "send");
    }

    // ---------------------------------------------------------------- traits

    /// coat 0 Blenheim, 1 Tricolour, 2 Black & Tan, 3 Ruby
    /// crown 0 none, 1 bronze, 2 silver, 3 gold, 4 diamond
    /// accessory 0 none, 1 bow tie, 2 scarf, 3 monocle, 4 shades
    /// eyes 0 bright, 1 wink, 2 sleepy
    function traits(uint256 id)
        public
        view
        returns (uint8 coat, uint8 bg, uint8 crown, uint8 accessory, uint8 eyes)
    {
        uint256 d = dna[id];
        require(d != 0, "no token");
        uint256 c = d % 100;
        coat = c < 40 ? 0 : c < 65 ? 1 : c < 85 ? 2 : 3;
        bg = uint8((d >> 8) % 6);
        uint256 k = (d >> 16) % 100;
        crown = k < 50 ? 0 : k < 80 ? 1 : k < 93 ? 2 : k < 99 ? 3 : 4;
        uint256 a = (d >> 24) % 100;
        accessory = a < 55 ? 0 : a < 70 ? 1 : a < 82 ? 2 : a < 92 ? 3 : 4;
        uint256 e = (d >> 32) % 10;
        eyes = e < 7 ? 0 : e < 9 ? 1 : 2;
    }

    /// Staking weight: 1 base, more for rarer crowns, +1 for any accessory, +1 for a Ruby coat.
    function weight(uint256 id) public view returns (uint256 w) {
        (uint8 coat,, uint8 crown, uint8 acc,) = traits(id);
        uint8[5] memory cw = [1, 2, 3, 5, 10];
        w = cw[crown];
        if (acc != 0) w += 1;
        if (coat == 3) w += 1;
    }

    // --------------------------------------------------------------- staking

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerWeight() public view returns (uint256) {
        if (totalWeight == 0) return rewardPerWeightStored;
        return rewardPerWeightStored + (lastTimeRewardApplicable() - lastUpdate) * rewardRate * 1e18 / totalWeight;
    }

    function earned(address u) public view returns (uint256) {
        return weightOf[u] * (rewardPerWeight() - rewardPerWeightPaid[u]) / 1e18 + rewards[u];
    }

    modifier updateReward(address u) {
        rewardPerWeightStored = rewardPerWeight();
        lastUpdate = lastTimeRewardApplicable();
        if (u != address(0)) {
            rewards[u] = earned(u);
            rewardPerWeightPaid[u] = rewardPerWeightStored;
        }
        _;
    }

    function stake(uint256[] calldata ids) external nonReentrant updateReward(msg.sender) {
        uint256 add;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (_ownerOf(id) != msg.sender) revert NotOwner(id);
            if (staked[id]) revert AlreadyStaked(id);
            staked[id] = true;
            uint256 w = weight(id);
            add += w;
            emit Staked(msg.sender, id, w);
        }
        weightOf[msg.sender] += add;
        totalWeight += add;
    }

    function unstake(uint256[] calldata ids) external nonReentrant updateReward(msg.sender) {
        uint256 sub;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (_ownerOf(id) != msg.sender) revert NotOwner(id);
            if (!staked[id]) revert NotStaked(id);
            staked[id] = false;
            uint256 w = weight(id);
            sub += w;
            emit Unstaked(msg.sender, id, w);
        }
        weightOf[msg.sender] -= sub;
        totalWeight -= sub;
    }

    function claim() public nonReentrant updateReward(msg.sender) {
        uint256 r = rewards[msg.sender];
        if (r > 0) {
            rewards[msg.sender] = 0;
            kings.safeTransfer(msg.sender, r);
            emit Claimed(msg.sender, r);
        }
    }

    /// Adds `amount` KingS (pulled from the caller) to be paid out over `duration` seconds.
    /// Leftovers of a running period roll into the new one.
    function notifyReward(uint256 amount, uint256 duration) external onlyOwner updateReward(address(0)) {
        if (duration == 0) revert BadDuration();
        kings.safeTransferFrom(msg.sender, address(this), amount);
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / duration;
        } else {
            uint256 left = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (amount + left) / duration;
        }
        // the contract must hold enough for the whole period (rewards owed but unclaimed included)
        if (rewardRate * duration > kings.balanceOf(address(this))) revert RateTooHigh();
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit RewardAdded(amount, duration);
    }

    /// Staked Cavaliers are locked in the owner's wallet until unstaked.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (staked[tokenId] && _ownerOf(tokenId) != address(0)) revert Locked(tokenId);
        return super._update(to, tokenId, auth);
    }

    // ----------------------------------------------------------------- views

    /// Owners, dna and staked flags for ids start..start+n-1 (1-based), for the gallery.
    function page(uint256 start, uint256 n)
        external
        view
        returns (address[] memory owners, uint256[] memory dnas, bool[] memory isStaked)
    {
        if (start == 0) start = 1;
        uint256 end = start + n;
        if (end > totalMinted + 1) end = totalMinted + 1;
        uint256 len = end > start ? end - start : 0;
        owners = new address[](len);
        dnas = new uint256[](len);
        isStaked = new bool[](len);
        for (uint256 i; i < len; i++) {
            uint256 id = start + i;
            owners[i] = _ownerOf(id);
            dnas[i] = dna[id];
            isStaked[i] = staked[id];
        }
    }

    // --------------------------------------------------------------- art

    function _pick(uint8 i, string memory a, string memory b, string memory c, string memory d)
        private
        pure
        returns (string memory)
    {
        return i == 0 ? a : i == 1 ? b : i == 2 ? c : d;
    }

    function coatName(uint8 c) public pure returns (string memory) {
        return _pick(c, "Blenheim", "Tricolour", "Black & Tan", "Ruby");
    }

    function crownName(uint8 c) public pure returns (string memory) {
        return c == 4 ? "Diamond" : _pick(c, "None", "Bronze", "Silver", "Gold");
    }

    function accessoryName(uint8 a) public pure returns (string memory) {
        return a == 4 ? "Shades" : _pick(a, "None", "Bow tie", "Scarf", "Monocle");
    }

    function eyesName(uint8 e) public pure returns (string memory) {
        return _pick(e, "Bright", "Wink", "Sleepy", "");
    }

    function _bg(uint8 b) private pure returns (string memory) {
        if (b == 4) return "#E6E0F5";
        if (b == 5) return "#F5E6C8";
        return _pick(b, "#F6E7D8", "#DCEBF5", "#E3F0DC", "#F7DDE2");
    }

    function _crownSvg(uint8 c) private pure returns (string memory) {
        if (c == 0) return "";
        string memory col = c == 4 ? "#9FE3F0" : _pick(c, "", "#B87333", "#C9CED6", "#E2B23C");
        string memory gem = c == 4 ? "#FFFFFF" : "#C0392B";
        return string.concat(
            '<path d="M21 15 L23.5 5.5 L28.5 11 L32 3.5 L35.5 11 L40.5 5.5 L43 15 Z" fill="', col,
            '"/><rect x="21" y="13.5" width="22" height="3.2" rx="1" fill="', col,
            '"/><circle cx="32" cy="9.5" r="1.3" fill="', gem, '"/>'
        );
    }

    function _eyesSvg(uint8 e) private pure returns (string memory) {
        if (e == 1) {
            return '<circle cx="25.6" cy="31.5" r="3" fill="#1B1A2E"/><circle cx="26.6" cy="30.4" r=".95" fill="#fff"/><path d="M35.6 31.6 q2.8 -2 5.6 0" stroke="#1B1A2E" stroke-width="1.6" fill="none" stroke-linecap="round"/>';
        }
        if (e == 2) {
            return '<path d="M22.8 31.6 q2.8 2 5.6 0 M35.6 31.6 q2.8 2 5.6 0" stroke="#1B1A2E" stroke-width="1.6" fill="none" stroke-linecap="round"/>';
        }
        return '<circle cx="25.6" cy="31.5" r="3" fill="#1B1A2E"/><circle cx="38.4" cy="31.5" r="3" fill="#1B1A2E"/><circle cx="26.6" cy="30.4" r=".95" fill="#fff"/><circle cx="39.4" cy="30.4" r=".95" fill="#fff"/>';
    }

    function _accSvg(uint8 a) private pure returns (string memory) {
        if (a == 1) return '<path d="M26 52 L32 54.5 L26 57 Z M38 52 L32 54.5 L38 57 Z" fill="#C0392B"/><circle cx="32" cy="54.5" r="1.4" fill="#8E2A1F"/>';
        if (a == 2) return '<path d="M20 50 Q32 57 44 50 L44 54 Q32 61 20 54 Z" fill="#2E86AB"/><path d="M38 54 l3 7 l3 -1 l-2 -7 Z" fill="#2E86AB"/>';
        if (a == 3) return '<circle cx="38.4" cy="31.5" r="4.4" fill="none" stroke="#E2B23C" stroke-width="1"/><path d="M42.8 32 q1 6 -1 10" stroke="#E2B23C" stroke-width=".6" fill="none"/>';
        if (a == 4) return '<rect x="21" y="28.5" width="9.5" height="5.5" rx="2" fill="#1B1A2E"/><rect x="33.5" y="28.5" width="9.5" height="5.5" rx="2" fill="#1B1A2E"/><path d="M30.5 30.5 h3" stroke="#1B1A2E" stroke-width="1.2"/>';
        return "";
    }

    function svg(uint256 id) public view returns (string memory) {
        (uint8 coat, uint8 bg, uint8 crown, uint8 acc, uint8 eyes) = traits(id);
        string memory head = _pick(coat, "#A84A1E", "#2A2530", "#2A2530", "#9C3B1A");
        string memory blaze = _pick(coat, "#FFF4E6", "#FFF4E6", "#C9773A", "#B8552C");
        string memory parts = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" fill="', _bg(bg), '"/>',
            '<path d="M17 21 C7 23 5 36 7 45 C8.5 52 15 56 20 51 C22.5 48.5 22.5 44 22 40 L22 25 Z" fill="', head, '"/>',
            '<path d="M47 21 C57 23 59 36 57 45 C55.5 52 49 56 44 51 C41.5 48.5 41.5 44 42 40 L42 25 Z" fill="', head, '"/>',
            '<path d="M19 26 C19 17.5 45 17.5 45 26 L45.5 37 C45.5 47 39.5 53 32 53 C24.5 53 18.5 47 18.5 37 Z" fill="', head, '"/>'
        );
        string memory face = string.concat(
            '<path d="M29.6 18.5 C30.6 17.6 33.4 17.6 34.4 18.5 L35.4 31 C39.5 33.5 41.3 39.5 39.6 44.5 C38 49.5 26 49.5 24.4 44.5 C22.7 39.5 24.5 33.5 28.6 31 Z" fill="', blaze, '"/>',
            coat == 1 ? '<circle cx="24.5" cy="36" r="2.2" fill="#C9773A"/><circle cx="39.5" cy="36" r="2.2" fill="#C9773A"/>' : "",
            _eyesSvg(eyes),
            '<ellipse cx="32" cy="39.6" rx="3.3" ry="2.4" fill="#1B1A2E"/><path d="M32 42 v2.6 M28.6 45.6 q3.4 2.4 6.8 0" stroke="#1B1A2E" stroke-width="1.3" fill="none" stroke-linecap="round"/>'
        );
        return string.concat(parts, face, _accSvg(acc), _crownSvg(crown), "</svg>");
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        (uint8 coat, uint8 bg, uint8 crown, uint8 acc, uint8 eyes) = traits(id);
        bg;
        string memory attrs = string.concat(
            '[{"trait_type":"Coat","value":"', coatName(coat),
            '"},{"trait_type":"Crown","value":"', crownName(crown),
            '"},{"trait_type":"Accessory","value":"', accessoryName(acc),
            '"},{"trait_type":"Eyes","value":"', eyesName(eyes),
            '"},{"trait_type":"Staking weight","display_type":"number","value":', weight(id).toString(), "}]"
        );
        string memory json = string.concat(
            '{"name":"Cavalier #', id.toString(),
            '","description":"A crowned Cavalier from the CavFi court on DogeOS. Art and traits are stored fully on-chain. Stake it on cavfi.com to earn KingS.","attributes":',
            attrs, ',"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg(id))), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
