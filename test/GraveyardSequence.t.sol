// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Graveyard} from "src/Graveyard.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Fresh actors keep burials live throughout the sequence instead of exhausting a small actor pool.
contract GraveyardSequenceHandler is Test {
    Graveyard public immutable cemetery;
    LaunchToken public immutable wake;
    MockERC20[3] public tokens;
    address[] public actors;
    uint256 public inflows;
    uint256 public paid;
    uint256 public flowersBurned;
    uint256 public burialCount;
    uint256 public mournerCount;
    mapping(address => uint256) public expectedBalance;
    mapping(address => uint256) public expectedEarned;
    mapping(address => uint256) public expectedBurials;
    mapping(address => mapping(address => bool)) public buried;
    uint256[3] public tokenBurns;
    uint256[3] public tokenMourners;
    uint256[3] public tokenFlowers;
    address[3] public firstMourner;
    uint256[3] public firstTime;
    bool[3] public written;
    bytes32[3] public epitaphHash;

    constructor(LaunchToken reward) {
        wake = reward;
        cemetery = new Graveyard(address(this));
        cemetery.setWakeToken(address(reward));
        address[] memory list = new address[](3);
        for (uint256 i; i < 3; ++i) {
            tokens[i] = new MockERC20(uint8(i * 9));
            list[i] = address(tokens[i]);
        }
        cemetery.consecrate(list);
    }

    function fund(uint256 raw, bool direct) external {
        uint256 balance = wake.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        if (direct) {
            wake.transfer(address(cemetery), amount);
        } else {
            wake.approve(address(cemetery), amount);
            cemetery.fund(amount);
        }
        inflows += amount;
    }

    function bury(uint256 seed, uint256 rawAmount, uint256 rawCount) external {
        uint256 count = bound(rawCount, 1, 3);
        uint256 offset = seed % 3;
        address actor = _freshActor();
        address[] memory batch = new address[](count);
        uint256 remaining = wake.balanceOf(address(cemetery));
        uint256 reward;
        uint256 amount = bound(rawAmount, 1, type(uint128).max);
        for (uint256 i; i < count; ++i) {
            uint256 index = (offset + i) % 3;
            batch[i] = address(tokens[index]);
            tokens[index].mint(actor, amount);
            vm.prank(actor);
            tokens[index].approve(address(cemetery), amount);
            uint256 next = remaining / 2000;
            reward += next;
            remaining -= next;
        }
        vm.prank(actor);
        uint256 actual = count == 1 ? cemetery.bury(batch[0]) : cemetery.buryMany(batch);
        assertEq(actual, reward, "sequential reward quote");
        assertEq(wake.balanceOf(address(cemetery)), remaining);
        for (uint256 i; i < count; ++i) {
            uint256 index = (offset + i) % 3;
            if (tokenMourners[index] == 0) {
                firstMourner[index] = actor;
                firstTime[index] = block.timestamp;
            }
            tokenMourners[index]++;
            tokenBurns[index] += amount;
            buried[actor][batch[i]] = true;
            assertEq(tokens[index].balanceOf(actor), 0);
        }
        expectedBalance[actor] = reward;
        expectedEarned[actor] = reward;
        expectedBurials[actor] = count;
        paid += reward;
        burialCount += count;
        mournerCount++;
    }

    function failedBatch(uint256 rawAmount) external {
        address actor = _freshActor();
        uint256 amount = bound(rawAmount, 1, type(uint128).max);
        address[] memory batch = new address[](3);
        for (uint256 i; i < 3; ++i) {
            batch[i] = address(tokens[i]);
            tokens[i].mint(actor, amount);
            vm.prank(actor);
            tokens[i].approve(address(cemetery), i == 2 ? amount - 1 : amount);
        }
        uint256 vault = wake.balanceOf(address(cemetery));
        vm.prank(actor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(cemetery), amount - 1, amount
            )
        );
        cemetery.buryMany(batch);
        assertEq(wake.balanceOf(address(cemetery)), vault);
        assertEq(wake.balanceOf(actor), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(tokens[i].balanceOf(actor), amount);
            assertEq(tokens[i].allowance(actor, address(cemetery)), i == 2 ? amount - 1 : amount);
        }
    }

    function flowers(uint256 actorSeed, uint256 tokenSeed, uint256 rawAmount) external {
        if (actors.length == 0) return;
        address actor = actors[actorSeed % actors.length];
        uint256 index = tokenSeed % 3;
        uint256 balance = expectedBalance[actor];
        if (balance == 0 || tokenMourners[index] == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);
        uint256 vault = wake.balanceOf(address(cemetery));
        vm.startPrank(actor);
        wake.approve(address(cemetery), amount);
        cemetery.layFlowers(address(tokens[index]), amount);
        vm.stopPrank();
        expectedBalance[actor] -= amount;
        flowersBurned += amount;
        tokenFlowers[index] += amount;
        assertEq(wake.balanceOf(address(cemetery)), vault, "flowers cannot spend reward funding");
    }

    function returnReward(uint256 actorSeed, uint256 rawAmount) external {
        if (actors.length == 0) return;
        address actor = actors[actorSeed % actors.length];
        uint256 balance = expectedBalance[actor];
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);
        vm.prank(actor);
        wake.transfer(address(cemetery), amount);
        expectedBalance[actor] -= amount;
        inflows += amount;
    }

    function epitaph(uint256 tokenSeed, bytes32 text, uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 365 days));
        uint256 index = tokenSeed % 3;
        if (tokenMourners[index] == 0) return;
        vm.prank(firstMourner[index]);
        if (written[index]) {
            vm.expectRevert(Graveyard.EpitaphAlreadyWritten.selector);
            cemetery.epitaph(address(tokens[index]), string(abi.encodePacked(text)));
        } else {
            cemetery.epitaph(address(tokens[index]), string(abi.encodePacked(text)));
            written[index] = true;
            epitaphHash[index] = keccak256(abi.encodePacked(text));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _freshActor() private returns (address actor) {
        actor = makeAddr(string.concat("sequence mourner ", vm.toString(actors.length)));
        actors.push(actor);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GraveyardSequenceTest is Test {
    GraveyardSequenceHandler private handler;
    Graveyard private cemetery;
    LaunchToken private wake;

    function setUp() public {
        wake = new LaunchToken();
        handler = new GraveyardSequenceHandler(wake);
        cemetery = handler.cemetery();
        wake.transfer(address(handler), wake.totalSupply());
        handler.fund(2000, false);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.bury.selector;
        selectors[2] = handler.failedBatch.selector;
        selectors[3] = handler.flowers.selector;
        selectors[4] = handler.returnReward.selector;
        selectors[5] = handler.epitaph.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function test_MixedSequenceExercisesEveryHandler() public {
        handler.fund(10_000, false);
        handler.bury(0, 1, 3);
        handler.failedBatch(1);
        handler.flowers(0, 0, 1);
        handler.returnReward(0, 1);
        handler.epitaph(0, bytes32("first"), 1);
        handler.epitaph(0, bytes32("second"), 1);
        assertEq(handler.actorCount(), 2);
        assertEq(cemetery.totalBurials(), 3);
        assertEq(cemetery.totalMourners(), 1);
        assertEq(cemetery.totalWakePaidOut(), 16);
        assertEq(cemetery.totalFlowersBurned(), 1);
        assertEq(
            cemetery.getTombstone(address(handler.tokens(0))).epitaphText, string(abi.encodePacked(bytes32("first")))
        );
        invariant_IndependentRewardAndFlowerLedger();
        invariant_IndependentBurialAndImmutableEpitaphLedger();
    }

    function invariant_IndependentRewardAndFlowerLedger() public view {
        assertEq(wake.totalSupply(), 1e27);
        assertEq(wake.balanceOf(address(cemetery)) + handler.paid(), handler.inflows());
        assertGt(wake.balanceOf(address(cemetery)), 0);
        assertEq(cemetery.totalWakePaidOut(), handler.paid());
        assertEq(cemetery.totalFlowersBurned(), handler.flowersBurned());
        assertEq(wake.balanceOf(cemetery.DEAD()), handler.flowersBurned());
        uint256 held =
            wake.balanceOf(address(handler)) + wake.balanceOf(address(cemetery)) + wake.balanceOf(cemetery.DEAD());
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertEq(wake.balanceOf(actor), handler.expectedBalance(actor));
            (uint256 burials, uint256 earned) = cemetery.walletRecords(actor);
            assertEq(burials, handler.expectedBurials(actor));
            assertEq(earned, handler.expectedEarned(actor));
            held += wake.balanceOf(actor);
        }
        assertEq(held, wake.totalSupply());
    }

    function invariant_IndependentBurialAndImmutableEpitaphLedger() public view {
        assertEq(cemetery.totalBurials(), handler.burialCount());
        assertEq(cemetery.totalMourners(), handler.mournerCount());
        uint256 tombstones;
        for (uint256 t; t < 3; ++t) {
            MockERC20 token = handler.tokens(t);
            Graveyard.Tombstone memory stone = cemetery.getTombstone(address(token));
            assertEq(stone.mourners, handler.tokenMourners(t));
            assertEq(stone.totalBuried, handler.tokenBurns(t));
            assertEq(token.balanceOf(cemetery.DEAD()), handler.tokenBurns(t));
            assertEq(stone.flowers, handler.tokenFlowers(t));
            assertEq(stone.firstMourner, handler.firstMourner(t));
            assertEq(stone.firstBurialTime, handler.firstTime(t));
            assertEq(stone.epitaphWritten, handler.written(t));
            if (stone.epitaphWritten) assertEq(keccak256(bytes(stone.epitaphText)), handler.epitaphHash(t));
            if (stone.mourners != 0) tombstones++;
            for (uint256 a; a < handler.actorCount(); ++a) {
                address actor = handler.actors(a);
                assertEq(cemetery.hasBuried(actor, address(token)), handler.buried(actor, address(token)));
            }
        }
        assertEq(cemetery.totalTokensBuried(), tombstones);
        assertEq(cemetery.consecratedCount(), 3);
        assertFalse(cemetery.consecrated(address(wake)));
        assertEq(address(cemetery.wakeToken()), address(wake));
        assertEq(cemetery.owner(), address(handler));
    }
}
