// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GraveyardBase} from "./GraveyardBase.sol";
import {Graveyard} from "../src/Graveyard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract GraveyardHandler is Test {
    Graveyard private immutable cemetery;
    LaunchToken private immutable wake;
    address private immutable owner;
    MockERC20[2] private tokens;
    address[4] public actors;
    uint256 public addedFunding;

    constructor(Graveyard target, LaunchToken reward, address admin, MockERC20 first, MockERC20 second) {
        cemetery = target;
        wake = reward;
        owner = admin;
        tokens = [first, second];
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
    }

    function bury(uint8 actorSeed, uint8 tokenSeed, uint96 rawAmount) external {
        address actor = actors[actorSeed % actors.length];
        MockERC20 token = tokens[tokenSeed % tokens.length];
        if (cemetery.hasBuried(actor, address(token))) return;
        uint256 amount = bound(rawAmount, 1, 1_000_000 ether);
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(cemetery), amount);
        cemetery.bury(address(token));
        vm.stopPrank();
    }

    function buryBoth(uint8 actorSeed, uint96 rawAmount) external {
        address actor = actors[actorSeed % actors.length];
        if (cemetery.hasBuried(actor, address(tokens[0])) || cemetery.hasBuried(actor, address(tokens[1]))) return;
        uint256 amount = bound(rawAmount, 1, 1_000_000 ether);
        address[] memory batch = new address[](2);
        for (uint256 i; i < tokens.length; ++i) {
            batch[i] = address(tokens[i]);
            tokens[i].mint(actor, amount);
            vm.prank(actor);
            tokens[i].approve(address(cemetery), amount);
        }
        vm.prank(actor);
        cemetery.buryMany(batch);
    }

    function fund(uint96 rawAmount) external {
        uint256 balance = wake.balanceOf(owner);
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance < 10_000 ether ? balance : 10_000 ether);
        vm.startPrank(owner);
        wake.approve(address(cemetery), amount);
        cemetery.fund(amount);
        vm.stopPrank();
        addedFunding += amount;
    }

    function donate(uint96 rawAmount) external {
        uint256 balance = wake.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);
        wake.transfer(address(cemetery), amount);
        addedFunding += amount;
    }

    function flowers(uint8 actorSeed, uint8 tokenSeed, uint96 rawAmount) external {
        address actor = actors[actorSeed % actors.length];
        address token = address(tokens[tokenSeed % tokens.length]);
        uint256 balance = wake.balanceOf(actor);
        if (balance == 0 || cemetery.getTombstone(token).mourners == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);
        vm.startPrank(actor);
        wake.approve(address(cemetery), amount);
        cemetery.layFlowers(token, amount);
        vm.stopPrank();
    }

    function epitaph(uint8 tokenSeed) external {
        address token = address(tokens[tokenSeed % tokens.length]);
        Graveyard.Tombstone memory stone = cemetery.getTombstone(token);
        if (stone.mourners == 0 || stone.epitaphWritten) return;
        vm.prank(stone.firstMourner);
        cemetery.epitaph(token, "Goodnight.");
    }
}

contract GraveyardInvariantTest is GraveyardBase {
    GraveyardHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new GraveyardHandler(graveyard, wake, owner, deadToken, otherToken);
        wake.transfer(address(handler), 100_000 ether);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = GraveyardHandler.bury.selector;
        selectors[1] = GraveyardHandler.buryBoth.selector;
        selectors[2] = GraveyardHandler.fund.selector;
        selectors[3] = GraveyardHandler.donate.selector;
        selectors[4] = GraveyardHandler.flowers.selector;
        selectors[5] = GraveyardHandler.epitaph.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_WakeConservationAndWalletAccounting() public view {
        assertEq(wake.balanceOf(address(graveyard)) + graveyard.totalWakePaidOut(), FUNDING + handler.addedFunding());
        assertGt(wake.balanceOf(address(graveyard)), 0);
        assertEq(graveyard.nextReward(), wake.balanceOf(address(graveyard)) / 2000);
        assertEq(wake.totalSupply(), 10 ** 27);
        assertEq(wake.balanceOf(DEAD), graveyard.totalFlowersBurned());
        uint256 earned;
        uint256 held;
        uint256 burials;
        uint256 mourners;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            (uint256 count, uint256 rewards) = graveyard.walletRecords(actor);
            earned += rewards;
            held += wake.balanceOf(actor);
            burials += count;
            if (count > 0) ++mourners;
            uint256 flags = graveyard.hasBuried(actor, address(deadToken)) ? 1 : 0;
            if (graveyard.hasBuried(actor, address(otherToken))) ++flags;
            assertEq(count, flags);
        }
        assertEq(earned, graveyard.totalWakePaidOut());
        assertEq(held + graveyard.totalFlowersBurned(), earned);
        assertEq(burials, graveyard.totalBurials());
        assertEq(mourners, graveyard.totalMourners());
    }

    function invariant_TombstonesMatchActualBurnsAndMourners() public view {
        Graveyard.Tombstone[] memory stones = graveyard.getTombstones(0, 100);
        uint256 burials;
        uint256 flowers;
        uint256 buriedTokens;
        assertEq(stones.length, 2);
        assertEq(graveyard.consecratedCount(), 2);
        assertEq(address(graveyard.wakeToken()), address(wake));
        assertEq(graveyard.owner(), owner);
        assertFalse(graveyard.consecrated(address(wake)));
        for (uint256 i; i < stones.length; ++i) {
            Graveyard.Tombstone memory stone = stones[i];
            assertEq(MockERC20(stone.token).balanceOf(DEAD), stone.totalBuried);
            uint256 flags;
            for (uint256 j; j < 4; ++j) {
                if (graveyard.hasBuried(handler.actors(j), stone.token)) ++flags;
            }
            assertEq(stone.mourners, flags);
            if (stone.mourners > 0) {
                ++buriedTokens;
                assertTrue(graveyard.hasBuried(stone.firstMourner, stone.token));
                assertLe(stone.firstBurialTime, block.timestamp);
            }
            if (stone.epitaphWritten) assertEq(stone.epitaphText, "Goodnight.");
            burials += stone.mourners;
            flowers += stone.flowers;
        }
        assertEq(burials, graveyard.totalBurials());
        assertEq(flowers, graveyard.totalFlowersBurned());
        assertEq(buriedTokens, graveyard.totalTokensBuried());
    }
}
