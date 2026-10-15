from dataclasses import replace
import unittest
from .w4a8_task import W4A8Task
from .w4a8_memory_task import W4A8MemoryTask
from .w4a8_runtime import W4A8Runtime, Completion


class MemoryTaskTests(unittest.TestCase):
    def setUp(self):
        self.d = W4A8Task(1, 2, 3, 37, 4093, 10001, 16000, 20000, 30004,
                          44, 24, 10, 14, 24)
        self.t = W4A8MemoryTask(self.d, 81, 67, 14, 20, 36)

    def test_padded_tail_and_serialization(self):
        self.assertEqual(self.t.validate().to_dict()['descriptor']['k'], 37)

    def test_existing_runtime_sends_capacities_and_waits_for_completion(self):
        class Transport:
            def write_descriptor(s, payload): s.payload = payload
            def ring_doorbell(s): s.submitted = True
            def read_completion(s): return Completion(1, 0)
            def read_tensor(s, *args): return args
        transport = Transport()
        runtime = W4A8Runtime(transport)
        runtime.submit(self.t)
        self.assertEqual(transport.payload['a_bytes'], 81)
        self.assertEqual(runtime.wait().task_id, 1)
        self.assertEqual(runtime.read_result(self.t), (30004, 2, 3, 24))

    def test_all_allocations_enforced(self):
        for name in ('a_bytes', 'w_bytes', 'sx_bytes', 'sw_bytes', 'y_bytes'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                replace(self.t, **{name: getattr(self.t, name)-1}).validate()

    def test_address_width_and_capacity_overflow(self):
        for addr in (1 << 32, (1 << 32)-4):
            with self.subTest(addr=addr), self.assertRaises(ValueError):
                replace(self.t, descriptor=replace(self.d, y_addr=addr)).validate()

    def test_output_cannot_alias_any_source_allocation(self):
        for addr in (4096, 10004, 16000, 20000):
            with self.subTest(addr=addr), self.assertRaises(ValueError):
                replace(self.t, descriptor=replace(self.d, y_addr=addr)).validate()

    def test_stride_alignment(self):
        for field in ('sx_stride', 'sw_stride', 'y_stride'):
            with self.subTest(field=field), self.assertRaises(ValueError):
                replace(self.t, descriptor=replace(self.d, **{field:getattr(self.d, field)+1})).validate()

    def test_wire_width_for_stride(self):
        with self.assertRaises(ValueError):
            replace(self.t, descriptor=replace(self.d, m=1, a_stride=1 << 32)).validate()

    def test_alternate_group_requires_matching_hardware(self):
        t = replace(self.t, descriptor=replace(self.d, group_size=12), sx_bytes=18, sw_bytes=48)
        t.validate(group_size=12)
        with self.assertRaises(ValueError):
            t.validate()


if __name__ == '__main__':
    unittest.main()
