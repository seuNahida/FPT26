#!/usr/bin/env python3
"""Small live Llama demonstration: persistent Prefill, Decode and inference logs."""
from __future__ import annotations

import argparse
from datetime import datetime
import logging
from pathlib import Path
import queue
import sys
import threading
import tkinter as tk
from tkinter import filedialog, ttk
from tkinter.scrolledtext import ScrolledText

from client.demo_session import DemoCancelled, DemoConfig, DemoSession

ROOT = Path(__file__).resolve().parents[1]
BG, INK, MUTED = '#f2f5fa', '#152b46', '#63768e'


def default_model():
    for path in (ROOT.parent/'Meta-Llama-3-8B', Path.home()/'Documents/Meta-Llama-3-8B',
                 Path.home()/'Models/Meta-Llama-3-8B'):
        if path.is_dir():
            return str(path)
    return ''


class QueueLogHandler(logging.Handler):
    def __init__(self, events):
        super().__init__()
        self.events = events

    def emit(self, record):
        self.events.put({'kind': 'log', 'line': self.format(record), 'level': record.levelno})


class ModelDemo:
    def __init__(self, root, *, model_path=None, host='192.168.1.10', port=50000,
                 context=2048, tokens=16, threads=8, backend='fpga_v4_udp',
                 log_dir=ROOT/'output/model_demo', session_factory=DemoSession):
        self.root, self.events = root, queue.Queue()
        self.context, self.port, self.threads, self.backend = context, port, threads, backend
        self.session_factory, self.session = session_factory, None
        self.busy = self.closing = self.can_decode = False
        self.worker = None
        self.cancel_event = threading.Event()
        self.remaining = context
        self.model_var = tk.StringVar(value=default_model() if model_path is None else model_path)
        self.host_var = tk.StringVar(value=host)
        self.count_var = tk.StringVar(value=str(tokens))
        self.state_var = tk.StringVar(value='输入提示词，然后点击 Prefill')
        self.preview_var = tk.StringVar(value='Prefill 后显示下一个 token 的预测')
        self.prefill_var = tk.StringVar(value='—')
        self.rate_var = tk.StringVar(value='—')
        self.generated_var = tk.StringVar(value='0')
        log_dir = Path(log_dir)
        log_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = log_dir / f'inference-{datetime.now().strftime("%Y%m%d-%H%M%S-%f")}.log'
        self.log = logging.getLogger(f'fpt.model_demo.{id(self)}')
        self.log.setLevel(logging.INFO)
        self.log.propagate = False
        formatter = logging.Formatter('%(asctime)s %(levelname)s %(message)s', datefmt='%H:%M:%S')
        for handler in (logging.StreamHandler(sys.stdout), logging.FileHandler(self.log_path, encoding='utf-8'),
                        QueueLogHandler(self.events)):
            handler.setFormatter(formatter)
            self.log.addHandler(handler)
        root.title('FPT v4.6 · 模型推理演示')
        root.geometry('1040x860')
        root.minsize(940,760)
        root.configure(bg=BG)
        root.columnconfigure(0,weight=1)
        root.rowconfigure(3,weight=1)
        root.protocol('WM_DELETE_WINDOW', self.close)
        self._build()
        self.model_var.trace_add('write', self.invalidate)
        self.host_var.trace_add('write', self.invalidate)
        self.prompt.bind('<<Modified>>', self._prompt_changed)
        self.prompt.edit_modified(False)
        self._buttons()
        self.log.info('展示端启动 backend=%s KV_capacity=%d log=%s', backend, context, self.log_path)
        root.after(50,self._drain)

    def _build(self):
        style=ttk.Style(self.root)
        style.theme_use('clam')
        style.configure('.',font=('Noto Sans CJK SC',10),foreground=INK)
        style.configure('TFrame',background=BG)
        style.configure('TLabel',background=BG)
        style.configure('TLabelframe',background=BG)
        style.configure('TLabelframe.Label',background=BG,font=('Noto Sans CJK SC',10,'bold'))
        style.configure('TButton',padding=(16,8))
        style.configure('Primary.TButton',background='#1659bd',foreground='white')
        style.map('Primary.TButton',background=[('disabled','#bdcce0'),('active','#10488e')])
        header=ttk.Frame(self.root,padding=(22,16,22,10))
        header.grid(row=0,column=0,sticky='ew')
        ttk.Label(header,text='FPT / Llama Demo',font=('Noto Sans CJK SC',21,'bold')).pack(side='left')
        label='v4.6 FPGA Attention · CPU 模型'
        ttk.Label(header,text=label,foreground=MUTED).pack(side='right')
        setup=ttk.Frame(self.root,padding=(22,0,22,6))
        setup.grid(row=1,column=0,sticky='ew')
        setup.columnconfigure(1,weight=1)
        ttk.Label(setup,text='本地模型').grid(row=0,column=0,padx=(0,8))
        self.model_entry=ttk.Entry(setup,textvariable=self.model_var)
        self.model_entry.grid(row=0,column=1,sticky='ew')
        self.browse_btn=ttk.Button(setup,text='选择目录',command=self.choose_model)
        self.browse_btn.grid(row=0,column=2,padx=8)
        ttk.Label(setup,text='FPGA IP').grid(row=0,column=3,padx=6)
        self.host_entry=ttk.Entry(setup,textvariable=self.host_var,width=15)
        self.host_entry.grid(row=0,column=4)
        ttk.Label(setup,text=f':{self.port}').grid(row=0,column=5,padx=(4,0))
        inputs=ttk.LabelFrame(self.root,text='提示词',padding=10)
        inputs.grid(row=2,column=0,sticky='ew',padx=22,pady=(6,10))
        self.prompt=tk.Text(inputs,height=3,wrap='word',font=('Noto Sans CJK SC',12),
                            relief='flat',bg='white',fg=INK,padx=8,pady=8)
        self.prompt.pack(fill='x')
        self.prompt.insert('1.0','The capital of France is')
        actions=ttk.Frame(inputs)
        actions.pack(fill='x',pady=(8,0))
        self.prefill_btn=ttk.Button(actions,text='① Prefill',style='Primary.TButton',command=self.prefill)
        self.prefill_btn.pack(side='left')
        self.decode_btn=ttk.Button(actions,text='② Decode',style='Primary.TButton',command=self.decode)
        self.decode_btn.pack(side='left',padx=8)
        ttk.Label(actions,text='本次生成').pack(side='left',padx=(12,4))
        self.count_entry=ttk.Entry(actions,textvariable=self.count_var,width=5)
        self.count_entry.pack(side='left')
        ttk.Label(actions,text='token').pack(side='left',padx=4)
        self.stop_btn=ttk.Button(actions,text='停止',command=self.stop)
        self.stop_btn.pack(side='right')
        result=ttk.LabelFrame(self.root,text='生成结果',padding=10)
        result.grid(row=3,column=0,sticky='nsew',padx=22)
        result.columnconfigure(0,weight=1)
        result.rowconfigure(1,weight=1)
        ttk.Label(result,textvariable=self.preview_var,foreground=MUTED).grid(row=0,column=0,sticky='w',pady=(0,6))
        self.output=ScrolledText(result,height=5,wrap='word',font=('Noto Sans CJK SC',17),
                                 state='disabled',relief='flat',bg='white',fg=INK,padx=12,pady=12)
        self.output.grid(row=1,column=0,sticky='nsew')
        metrics=ttk.Frame(result)
        metrics.grid(row=2,column=0,sticky='ew',pady=(10,0))
        for label,var in [('Prefill / ms',self.prefill_var),('本次 Decode / token/s',self.rate_var),('累计生成 / token',self.generated_var)]:
            box=ttk.Frame(metrics)
            box.pack(side='left',fill='x',expand=True)
            ttk.Label(box,text=label,foreground=MUTED).pack(anchor='w')
            ttk.Label(box,textvariable=var,font=('Noto Sans CJK SC',17,'bold')).pack(anchor='w')
        footer=ttk.Frame(self.root,padding=(22,8))
        footer.grid(row=4,column=0,sticky='ew')
        ttk.Label(footer,textvariable=self.state_var).pack(side='left')
        self.progress=ttk.Progressbar(footer,mode='indeterminate',length=120)
        self.progress.pack(side='right')
        logs=ttk.LabelFrame(self.root,text='后台推理日志（同时输出到终端与文件）',padding=6)
        logs.grid(row=5,column=0,sticky='ew',padx=22,pady=(0,8))
        self.log_view=ScrolledText(logs,height=5,wrap='word',font=('Noto Sans Mono CJK SC',9),
                                  state='disabled',bg='#15263b',fg='#dbe8f8',relief='flat')
        self.log_view.pack(fill='both',expand=True)
        self.log_view.tag_configure('error',foreground='#ffb4a7')
        ttk.Label(self.root,text=f'日志文件：{self.log_path}',foreground=MUTED,
                  font=('Noto Sans CJK SC',8)).grid(row=6,column=0,sticky='w',padx=22,pady=(0,8))

    def _buttons(self):
        idle=not self.busy and not self.closing
        for widget in (self.model_entry,self.host_entry,self.browse_btn,self.count_entry,self.prefill_btn):
            widget.configure(state='normal' if idle else 'disabled')
        self.prompt.configure(state='normal' if idle else 'disabled')
        self.decode_btn.configure(state='normal' if idle and self.can_decode else 'disabled')
        self.stop_btn.configure(state='normal' if self.busy and not self.closing else 'disabled')

    def choose_model(self):
        path=filedialog.askdirectory(title='选择本地 Llama 模型目录')
        if path:self.model_var.set(path)

    def invalidate(self,*_):
        if not self.busy:
            self.can_decode=False
            self.state_var.set('输入已更改，请重新 Prefill')
            self._buttons()

    def _prompt_changed(self,_=None):
        if self.prompt.edit_modified():
            self.prompt.edit_modified(False)
            self.invalidate()

    def _set_output(self,text):
        self.output.configure(state='normal')
        self.output.delete('1.0','end')
        self.output.insert('1.0',text)
        self.output.see('end')
        self.output.configure(state='disabled')

    def prefill(self):
        if self.busy or self.closing:return
        prompt=self.prompt.get('1.0','end-1c')
        try:
            if not prompt.strip():raise ValueError('请输入提示词')
            config=DemoConfig(self.model_var.get().strip(),self.host_var.get().strip(),
                              self.port,self.context,self.backend,self.threads)
        except ValueError as exc:
            self.state_var.set(str(exc));self.log.warning('%s',exc);return
        self.can_decode=False
        self.generated_var.set('0');self.prefill_var.set('—');self.rate_var.set('—')
        self.preview_var.set('正在准备 Prefill…');self._set_output('')
        self._start('prefill',config,prompt)

    def decode(self):
        if self.busy or self.closing or not self.can_decode:return
        try:
            count=int(self.count_var.get())
            if not 1 <= count <= self.remaining:
                raise ValueError(f'本次生成 token 数须为 1–{self.remaining}')
        except ValueError as exc:
            self.state_var.set(str(exc));self.log.warning('%s',exc);return
        self._start('decode',self.session.config,count)

    def _start(self,operation,config,value):
        self.busy=True
        self.cancel_event=threading.Event()
        self.state_var.set('正在检查设备并加载模型…' if operation=='prefill' else 'Decode 正在接续生成…')
        self.progress.start(15);self._buttons()
        def work():
            try:
                if self.session is None or self.session.config!=config:
                    if self.session is not None:self.session.close()
                    self.session=self.session_factory(config,emit=self.events.put,logger=self.log)
                result=getattr(self.session,operation)(value,self.cancel_event)
                self.events.put({'kind':'success','operation':operation,'result':result})
            except DemoCancelled as exc:
                self.session.reset_context()
                self.log.info('%s',exc)
                self.events.put({'kind':'cancelled','message':str(exc)})
            except Exception as exc:
                if self.session is not None:self.session.reset_context()
                self.log.exception('%s 失败',operation)
                self.events.put({'kind':'error','message':str(exc)})
            finally:self.events.put({'kind':'finished'})
        self.worker=threading.Thread(target=work,name='model-inference',daemon=False)
        self.worker.start()

    def stop(self):
        if self.busy:
            self.cancel_event.set()
            self.state_var.set('正在收尾当前 Attention 作业…')
            self.log.info('请求停止：等待当前 Attention 作业完成，不中断 FPGA 传输')

    def close(self):
        self.closing=True;self._buttons()
        if self.busy:self.stop()
        self._close_when_idle()

    def _close_when_idle(self):
        if self.worker is not None and self.worker.is_alive():
            self.root.after(100,self._close_when_idle)
            return
        if self.session is not None:self.session.close()
        self.log.info('展示端关闭，模型会话已释放')
        for handler in self.log.handlers[:]:
            handler.close();self.log.removeHandler(handler)
        self.root.destroy()

    def _drain(self):
        try:
            for _ in range(150):
                event=self.events.get_nowait();kind=event['kind']
                if kind=='log':
                    self.log_view.configure(state='normal')
                    self.log_view.insert('end',event['line']+'\n','error' if event['level']>=logging.ERROR else '')
                    if int(self.log_view.index('end-1c').split('.')[0])>1200:self.log_view.delete('1.0','200.0')
                    self.log_view.see('end');self.log_view.configure(state='disabled')
                elif kind=='phase':self.state_var.set(event['text'])
                elif kind=='layer':self.state_var.set(f'Attention 层进度 {event["layer"]}/{event["layers"]}')
                elif kind=='token':
                    self._set_output(event['text']);self.generated_var.set(str(event['generated']))
                    self.state_var.set(f'Decode · 本次 {event["step"]}/{event["requested"]} token')
                elif kind=='success':
                    result=event['result'];self.can_decode=result['can_decode'];self.remaining=result['remaining']
                    if event['operation']=='prefill':
                        self.prefill_var.set(f'{result["prefill_ms"]:.1f}')
                        self.preview_var.set(f'输入 {result["prompt_tokens"]} token · 下一个 token 预测：{result["next_token"]!r}')
                        self.state_var.set('Prefill 完成 · 点击 Decode 接续生成')
                    else:
                        self._set_output(result['text']);self.generated_var.set(str(result['generated']))
                        self.rate_var.set(f'{result["tokens_per_s"]:.2f}')
                        self.state_var.set('已生成结束标记，请开始新的 Prefill' if result['eos'] else
                                           'KV 容量已满，请开始新的 Prefill' if not result['can_decode'] else
                                           'Decode 完成 · 可继续 Decode，或输入新提示词后 Prefill')
                elif kind in ('error','cancelled'):
                    self.can_decode=False;self.state_var.set(event['message'])
                elif kind=='finished':
                    self.busy=False;self.progress.stop();self._buttons()
        except queue.Empty:pass
        if not self.closing:self.root.after(50,self._drain)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-path',default=None)
    parser.add_argument('--host',default='192.168.1.10')
    parser.add_argument('--port',type=int,default=50000)
    parser.add_argument('--context',type=int,default=2048)
    parser.add_argument('--tokens',type=int,default=16)
    parser.add_argument('--threads',type=int,default=8)
    parser.add_argument('--log-dir',type=Path,default=ROOT/'output/model_demo')
    args=parser.parse_args(argv)
    if not 1 < args.context <= 8192 or not 1 <= args.tokens < args.context or not 1 <= args.threads <= 64:
        parser.error('请检查 KV 容量、生成数量和 CPU 线程数')
    root=tk.Tk()
    app=ModelDemo(root,model_path=args.model_path,host=args.host,port=args.port,
                  context=args.context,tokens=args.tokens,threads=args.threads,
                  backend='fpga_v4_udp',log_dir=args.log_dir)
    try:root.mainloop()
    except KeyboardInterrupt:
        app.close()
        root.mainloop()
    return 0


if __name__=='__main__':
    raise SystemExit(main())
