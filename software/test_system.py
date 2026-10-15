from dataclasses import replace
import unittest
from .system import AttentionTask,FFNPlan,KVConfig,KVCommand,Opcode,ProjectRuntime,SystemJob
from .w4a8_task import W4A8Task
from .w4a8_memory_task import W4A8MemoryTask
from .w4a8_runtime import Completion

def bounded(tag,m,n,k,bases):
    g=(k+31)//32;s=[k,(k+1)//2,2*g,2*n,4*n]
    d=W4A8Task(tag,m,n,k,*bases,*s)
    return W4A8MemoryTask(d,m*s[0],n*s[1],m*s[2],g*s[3],m*s[4])

class SystemTests(unittest.TestCase):
    def setUp(self):
        b=1<<32
        self.g=bounded(11,1,9,5,[b+x for x in (1024,2048,3072,4096,5120)])
        self.u=bounded(12,1,9,5,[b+x for x in (1024,6144,3072,7168,8192)])
        self.d=bounded(13,1,3,9,[b+x for x in (9216,10240,11264,12288,13312)])
        self.plan=FFNPlan(10,self.g,self.u,self.d)

    def test_high_address_ffn_and_wire_schema(self):
        job=SystemJob(Opcode.FFN,self.plan).validate();wire=job.to_dict()
        self.assertEqual(wire['abi_version'],2)
        self.assertEqual(wire['ffn_plan']['gate_task']['desc']['a_addr'],(1<<32)+1024)
        with self.assertRaises(ValueError):self.plan.validate(addr_width=32)

    def test_graph_and_live_workspace_alias(self):
        for bad in (replace(self.plan,up_task=replace(self.u,descriptor=replace(self.u.descriptor,task_id=11))),
                    replace(self.plan,down_task=replace(self.d,descriptor=replace(self.d.descriptor,k=8))),
                    replace(self.plan,up_task=replace(self.u,descriptor=replace(self.u.descriptor,y_addr=self.g.y_addr)))):
            with self.subTest(plan=bad),self.assertRaises(ValueError):bad.validate()

    def test_kv_address_space_and_causal_prefix(self):
        cfg=KVConfig(1,1,1,8,9,32,tuple((2<<32)+x for x in (1024,4096,8192,12288)),(128,128,32,32),(16,16,4,4),(128,128,32,32),(128,128,32,32))
        cfg.validate()
        task=AttentionTask(2,0,0,3,9,1365,(2<<32)+16384,36)
        task.validate(config=cfg,committed=3)
        for bad in (replace(task,tokens=4),replace(task,y_addr=cfg.base[0]),replace(task,y_addr=(1<<64)-4)):
            with self.subTest(task=bad),self.assertRaises(ValueError):bad.validate(config=cfg,committed=3)

    def test_transport_gets_one_versioned_job_and_actual_completion(self):
        class Transport:
            def write_descriptor(s,payload):s.payload=payload
            def ring_doorbell(s):s.count=getattr(s,'count',0)+1
            def read_completion(s):return Completion(10,0)
        t=Transport();runtime=ProjectRuntime(t);runtime.submit(SystemJob(Opcode.FFN,self.plan))
        self.assertEqual(t.payload['job_opcode'],1)
        with self.assertRaises(RuntimeError):runtime.submit(SystemJob(Opcode.FFN,self.plan))
        self.assertEqual(runtime.wait().task_id,10);self.assertEqual(t.count,1)

    def test_unknown_opcode_never_reaches_transport(self):
        with self.assertRaises(ValueError):SystemJob(99,self.plan).validate()

    def test_kv_command_schema_and_limits(self):
        job=SystemJob(Opcode.KV_COMMAND,KVCommand(88,0,token=1,count=2)).validate()
        self.assertEqual(job.to_dict()['kv_command']['count'],2)
        with self.assertRaises(ValueError):SystemJob(Opcode.KV_COMMAND,KVCommand(89,0,token=15,count=2)).validate()

if __name__=='__main__':unittest.main()
