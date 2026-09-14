import copy
import json
import unittest
import sys
sys.dont_write_bytecode = True
from storage_layout import BASELINE, check_layout, check_selectors


class StorageLayoutTest(unittest.TestCase):
    def setUp(self):
        self.base = json.loads(BASELINE.read_text())
        self.new = copy.deepcopy(self.base)

    def test_append_allowed(self):
        self.new["storage"].append(dict(label="upgradeValue", slot="91", offset=0,
                                        type="uint256", numberOfBytes="32"))
        check_layout(self.base, self.new)

    def test_reorder_type_offset_removal_rejected(self):
        for key, value in [("slot", "92"), ("offset", 1), ("type", "uint128")]:
            candidate = copy.deepcopy(self.base)
            candidate["storage"][0][key] = value
            with self.assertRaises(ValueError):
                check_layout(self.base, candidate)
        self.new["storage"].pop()
        with self.assertRaises(ValueError):
            check_layout(self.base, self.new)

    def test_struct_member_change_rejected(self):
        self.new["structs"][0]["members"].reverse()
        with self.assertRaises(ValueError):
            check_layout(self.base, self.new)

    def test_gap_consumption_rejected(self):
        self.new["storage"].append(dict(label="newField", slot="1", offset=0,
                                        type="uint256", numberOfBytes="32"))
        with self.assertRaises(ValueError):
            check_layout(self.base, self.new)

    def test_selector_collision_uses_bytes_not_name(self):
        with self.assertRaises(ValueError):
            check_selectors({"implementation()": "5c60da1b"}, {"differentName()": "5c60da1b"})
        check_selectors({"implementation()": "5c60da1b"}, {"owner()": "8da5cb5b"})


if __name__ == "__main__":
    unittest.main()
