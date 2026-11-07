import collections
import contextlib
import errno
import io
import json
import unittest
from unittest.mock import patch

import watch_detection


class MotionWatcherTests(unittest.TestCase):
    def poll(self, alarms):
        camera = "192.168.50.20"
        unreachable = "192.168.50.21"
        clock = 0.0
        values = iter(alarms)
        queue = collections.deque()

        class FakeSocket:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def sendto(self, _packet, address):
                if address[0] == unreachable:
                    raise OSError(errno.ENETUNREACH, "Synthetic route failure")
                alarm = next(values)
                reply = {"device_type": "SMART.IPCAMERA"}
                if alarm is not None:
                    reply["last_alarm_time"] = alarm
                queue.append((b"\0" * 16 + json.dumps({"result": reply}).encode(), address))

            def recvfrom(self, _size):
                return queue.popleft()

        def select(sockets, _writes, _errors, remaining):
            nonlocal clock
            if queue:
                return sockets, [], []
            clock += remaining
            return [], [], []

        output = io.StringIO()
        with (
            patch.object(watch_detection, "discovery_body", return_value=b"fixture"),
            patch.object(watch_detection.socket, "socket", return_value=FakeSocket()),
            patch.object(watch_detection.time, "monotonic", side_effect=lambda: clock),
            patch.object(watch_detection.select, "select", side_effect=select),
            contextlib.redirect_stdout(output),
        ):
            watch_detection.watch({camera, unreachable}, len(alarms) / 4, True)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_first_motion_after_zero_or_missing_alarm_and_bad_route(self):
        for empty in (0, None):
            with self.subTest(empty=empty):
                events = self.poll([empty, 100, 101])
                self.assertEqual(events[0], {"type": "ready"})
                self.assertEqual(
                    [event["reason"] for event in events if event["type"] == "error"],
                    ["UDP probe failed (ENETUNREACH)"],
                )
                self.assertEqual([event["alarm"] for event in events if event.get("motion")], [100, 101])

    def test_existing_alarm_at_start_is_only_a_baseline(self):
        events = self.poll([99, 100, 100])
        self.assertEqual([event["alarm"] for event in events if event.get("motion")], [100])


if __name__ == "__main__":
    unittest.main()
