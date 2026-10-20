import unittest

import homemesh


class SmokeTest(unittest.TestCase):
    def test_version(self):
        self.assertEqual(homemesh.__version__, "0.0.0")


if __name__ == "__main__":
    unittest.main()
