// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {RgbRejectList} from "../src/RgbRejectList.sol";
import {IRgbRejectList} from "../src/interfaces/IRgbRejectList.sol";

contract RgbRejectListTest is Test {
    event EntryAdded(uint256 indexed index, bytes32 indexed opId, bool reject);
    event AppenderUpdated(address indexed previousAppender, address indexed newAppender);

    RgbRejectList list;

    address owner = makeAddr("owner");
    address appender = makeAddr("appender");
    address stranger = makeAddr("stranger");

    function setUp() public {
        list = new RgbRejectList(owner, appender);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _opId(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("rgb-op", i));
    }

    function _entry(uint256 i) internal pure returns (IRgbRejectList.Entry memory) {
        return IRgbRejectList.Entry({opId: _opId(i), reject: i % 2 == 0});
    }

    /// @dev Entries for ids `[from, from + n)`.
    function _batch(uint256 from, uint256 n) internal pure returns (IRgbRejectList.Entry[] memory b) {
        b = new IRgbRejectList.Entry[](n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = _entry(from + i);
        }
    }

    function _append(uint256 from, uint256 n) internal {
        vm.prank(appender);
        list.append(_batch(from, n));
    }

    function _assertEntry(IRgbRejectList.Entry memory got, uint256 i) internal pure {
        assertEq(got.opId, _opId(i), "opId");
        assertEq(got.reject, i % 2 == 0, "reject flag");
    }

    // =========================================================================
    // Construction
    // =========================================================================

    function test_constructor_setsRoles() public view {
        assertEq(list.owner(), owner);
        assertEq(list.appender(), appender);
        assertEq(list.pendingOwner(), address(0));
    }

    function test_constructor_emitsAppenderUpdated() public {
        vm.expectEmit(true, true, false, false);
        emit AppenderUpdated(address(0), appender);
        new RgbRejectList(owner, appender);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RgbRejectList(address(0), appender);
    }

    function test_constructor_revertsOnZeroAppender() public {
        vm.expectRevert(IRgbRejectList.InvalidAppender.selector);
        new RgbRejectList(owner, address(0));
    }

    function test_constructor_startsEmpty() public view {
        assertEq(list.length(), 0);
        assertEq(list.entries(0, 10).length, 0);
    }

    // =========================================================================
    // append
    // =========================================================================

    function test_append_storesEntriesInOrder() public {
        _append(0, 5);

        assertEq(list.length(), 5);
        IRgbRejectList.Entry[] memory page = list.entries(0, 5);
        for (uint256 i = 0; i < 5; i++) {
            _assertEntry(page[i], i);
        }
    }

    function test_append_marksEntriesListed() public {
        _append(0, 3);

        for (uint256 i = 0; i < 3; i++) {
            assertTrue(list.isListed(_opId(i)), "appended opId is listed");
        }
        assertFalse(list.isListed(_opId(3)), "other opId is not listed");
    }

    /// @notice Indices are global across batches, so a client can key its cache
    ///         on them.
    function test_append_emitsEntryAddedWithGlobalIndex() public {
        _append(0, 2);

        vm.expectEmit(true, true, false, true, address(list));
        emit EntryAdded(2, _opId(2), true);
        vm.expectEmit(true, true, false, true, address(list));
        emit EntryAdded(3, _opId(3), false);
        _append(2, 2);
    }

    function test_append_revertsForStranger() public {
        IRgbRejectList.Entry[] memory b = _batch(0, 1);

        vm.expectRevert(abi.encodeWithSelector(IRgbRejectList.NotAppender.selector, stranger));
        vm.prank(stranger);
        list.append(b);
    }

    /// @notice The owner is a cold administrative key and cannot append; that
    ///         keeps the two roles genuinely separate.
    function test_append_revertsForOwner() public {
        IRgbRejectList.Entry[] memory b = _batch(0, 1);

        vm.expectRevert(abi.encodeWithSelector(IRgbRejectList.NotAppender.selector, owner));
        vm.prank(owner);
        list.append(b);
    }

    function test_append_revertsOnEmptyBatch() public {
        IRgbRejectList.Entry[] memory b = new IRgbRejectList.Entry[](0);

        vm.expectRevert(IRgbRejectList.EmptyBatch.selector);
        vm.prank(appender);
        list.append(b);
    }

    function test_append_revertsOnZeroOpId() public {
        IRgbRejectList.Entry[] memory b = new IRgbRejectList.Entry[](1);
        b[0] = IRgbRejectList.Entry({opId: bytes32(0), reject: true});

        vm.expectRevert(IRgbRejectList.InvalidOpId.selector);
        vm.prank(appender);
        list.append(b);
    }

    function test_append_revertsOnDuplicateAcrossBatches() public {
        _append(0, 1);
        IRgbRejectList.Entry[] memory b = _batch(0, 1);

        vm.expectRevert(abi.encodeWithSelector(IRgbRejectList.AlreadyListed.selector, _opId(0)));
        vm.prank(appender);
        list.append(b);
    }

    /// @notice A decision can never be overwritten, not even by flipping the
    ///         flag for the same operation id.
    function test_append_revertsOnDuplicateWithOppositeFlag() public {
        _append(0, 1); // id 0 is a reject
        IRgbRejectList.Entry[] memory b = new IRgbRejectList.Entry[](1);
        b[0] = IRgbRejectList.Entry({opId: _opId(0), reject: false});

        vm.expectRevert(abi.encodeWithSelector(IRgbRejectList.AlreadyListed.selector, _opId(0)));
        vm.prank(appender);
        list.append(b);
    }

    function test_append_revertsOnDuplicateWithinBatch() public {
        IRgbRejectList.Entry[] memory b = new IRgbRejectList.Entry[](2);
        b[0] = _entry(7);
        b[1] = _entry(7);

        vm.expectRevert(abi.encodeWithSelector(IRgbRejectList.AlreadyListed.selector, _opId(7)));
        vm.prank(appender);
        list.append(b);
    }

    /// @notice A batch is recorded entirely or not at all: entries before the
    ///         offending one are rolled back too.
    function test_append_isAtomic() public {
        _append(0, 1);
        IRgbRejectList.Entry[] memory b = new IRgbRejectList.Entry[](3);
        b[0] = _entry(1);
        b[1] = _entry(2);
        b[2] = _entry(0); // duplicate of an existing entry

        vm.expectRevert(abi.encodeWithSelector(IRgbRejectList.AlreadyListed.selector, _opId(0)));
        vm.prank(appender);
        list.append(b);

        assertEq(list.length(), 1, "nothing from the failed batch recorded");
        assertFalse(list.isListed(_opId(1)), "first entry rolled back");
        assertFalse(list.isListed(_opId(2)), "second entry rolled back");
    }

    /// @notice Append-only: entries already written are never altered by later
    ///         appends. The incremental client sync depends on this.
    function test_append_neverModifiesExistingEntries() public {
        _append(0, 4);
        IRgbRejectList.Entry[] memory before = list.entries(0, 4);

        _append(4, 10);

        IRgbRejectList.Entry[] memory afterwards = list.entries(0, 4);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(afterwards[i].opId, before[i].opId, "opId unchanged");
            assertEq(afterwards[i].reject, before[i].reject, "flag unchanged");
        }
    }

    // =========================================================================
    // entries
    // =========================================================================

    function test_entries_returnsExactRange() public {
        _append(0, 10);

        IRgbRejectList.Entry[] memory page = list.entries(3, 7);
        assertEq(page.length, 4);
        for (uint256 i = 0; i < 4; i++) {
            _assertEntry(page[i], 3 + i);
        }
    }

    function test_entries_clampsEndToLength() public {
        _append(0, 5);

        IRgbRejectList.Entry[] memory page = list.entries(3, 1000);
        assertEq(page.length, 2);
        _assertEntry(page[0], 3);
        _assertEntry(page[1], 4);
    }

    function test_entries_emptyWhenStartAtOrPastLength() public {
        _append(0, 5);

        assertEq(list.entries(5, 10).length, 0, "start == length");
        assertEq(list.entries(6, 10).length, 0, "start > length");
    }

    function test_entries_emptyWhenStartNotBeforeEnd() public {
        _append(0, 5);

        assertEq(list.entries(3, 3).length, 0, "start == end");
        assertEq(list.entries(4, 2).length, 0, "start > end");
    }

    function test_entries_handlesMaxRange() public {
        _append(0, 3);

        assertEq(list.entries(0, type(uint256).max).length, 3, "end clamped");
        assertEq(list.entries(type(uint256).max, type(uint256).max).length, 0, "start past end");
    }

    /// @notice Reading the list in pages of any size reproduces it exactly.
    function testFuzz_entries_pagesReconstructList(uint256 n, uint256 pageSize) public {
        n = bound(n, 0, 120);
        pageSize = bound(pageSize, 1, 150);
        if (n > 0) _append(0, n);

        uint256 cached;
        while (cached < list.length()) {
            IRgbRejectList.Entry[] memory page = list.entries(cached, cached + pageSize);
            assertGt(page.length, 0, "a non-empty remainder always yields entries");
            for (uint256 i = 0; i < page.length; i++) {
                _assertEntry(page[i], cached + i);
            }
            cached += page.length;
        }
        assertEq(cached, n, "every entry read exactly once");
    }

    /// @notice The intended client flow: a full sync, then an incremental sync
    ///         that fetches only the entries appended since.
    function test_clientSync_fullThenOnlyNewTail() public {
        uint256 pageSize = 10;
        _append(0, 23);

        uint256 cached;
        uint256 calls;
        uint256 len = list.length();
        while (cached < len) {
            cached += list.entries(cached, cached + pageSize).length;
            calls++;
        }
        assertEq(cached, 23);
        assertEq(calls, 3, "23 entries at page 10 take 3 calls");

        _append(23, 4);

        calls = 0;
        len = list.length();
        while (cached < len) {
            IRgbRejectList.Entry[] memory page = list.entries(cached, cached + pageSize);
            _assertEntry(page[0], cached);
            cached += page.length;
            calls++;
        }
        assertEq(cached, 27);
        assertEq(calls, 1, "only the new tail is fetched");
    }

    // =========================================================================
    // setAppender
    // =========================================================================

    /// @notice Rotating the appender hands append rights to the new key and
    ///         revokes them from the old one — the recovery path for a leaked
    ///         tool key.
    function test_setAppender_rotatesAppendRights() public {
        address newAppender = makeAddr("newAppender");
        _append(0, 1);

        vm.expectEmit(true, true, false, false, address(list));
        emit AppenderUpdated(appender, newAppender);
        vm.prank(owner);
        list.setAppender(newAppender);
        assertEq(list.appender(), newAppender);

        vm.prank(newAppender);
        list.append(_batch(1, 1));
        assertEq(list.length(), 2, "new appender can append");

        IRgbRejectList.Entry[] memory b = _batch(2, 1);
        vm.expectRevert(abi.encodeWithSelector(IRgbRejectList.NotAppender.selector, appender));
        vm.prank(appender);
        list.append(b);
    }

    /// @notice Rotation does not touch entries already in the list.
    function test_setAppender_keepsExistingEntries() public {
        _append(0, 3);

        vm.prank(owner);
        list.setAppender(makeAddr("newAppender"));

        assertEq(list.length(), 3);
        IRgbRejectList.Entry[] memory page = list.entries(0, 3);
        for (uint256 i = 0; i < 3; i++) {
            _assertEntry(page[i], i);
        }
    }

    function test_setAppender_revertsOnZeroAddress() public {
        vm.expectRevert(IRgbRejectList.InvalidAppender.selector);
        vm.prank(owner);
        list.setAppender(address(0));
    }

    /// @notice A compromised appender cannot appoint a replacement, so it
    ///         cannot lock the owner out of the role it controls.
    function test_setAppender_revertsForAppender() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, appender));
        vm.prank(appender);
        list.setAppender(stranger);
    }

    function test_setAppender_revertsForStranger() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        list.setAppender(stranger);
    }

    // =========================================================================
    // Ownership
    // =========================================================================

    function test_ownership_twoStepTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        list.transferOwnership(newOwner);
        assertEq(list.owner(), owner, "owner unchanged until accepted");
        assertEq(list.pendingOwner(), newOwner);

        vm.prank(newOwner);
        list.acceptOwnership();
        assertEq(list.owner(), newOwner);
        assertEq(list.appender(), appender, "ownership transfer leaves the appender unchanged");

        // the new owner administers the appender, the previous one no longer can
        vm.prank(newOwner);
        list.setAppender(stranger);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        list.setAppender(appender);
    }

    function test_ownership_pendingOwnerCannotSetAppenderBeforeAccepting() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        list.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        list.setAppender(stranger);
    }

    function test_renounceOwnership_isBlocked() public {
        vm.expectRevert(RgbRejectList.RenounceOwnershipBlocked.selector);
        vm.prank(owner);
        list.renounceOwnership();

        assertEq(list.owner(), owner, "owner unchanged");
    }

    function test_renounceOwnership_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        list.renounceOwnership();
    }
}
