from __future__ import annotations

import queue
import sys
import tempfile
import threading
import traceback
import webbrowser
from pathlib import Path
from tkinter import BOTH, END, LEFT, RIGHT, X, filedialog, messagebox
import tkinter as tk
from tkinter import ttk

import cv2
import numpy as np

from analysis_core import SimilarityResult, analyze_video


class SimilarityLab(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("视频相似度离线实验室")
        self.geometry("1040x690")
        self.minsize(940, 620)
        self.configure(bg="#f4f7fb")
        self._events: queue.Queue[tuple[str, object]] = queue.Queue()
        self._report_path: str | None = None

        self.video_var = tk.StringVar()
        self.output_var = tk.StringVar()
        self.seconds_var = tk.IntVar(value=60)
        self.status_var = tk.StringVar(value="请选择一段你有权使用的本地视频")
        self.progress_var = tk.DoubleVar(value=0)

        self._configure_style()
        self._build_ui()
        self.after(100, self._drain_events)

    def _configure_style(self) -> None:
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            pass
        style.configure("Title.TLabel", font=("Microsoft YaHei UI", 21, "bold"), background="#f4f7fb")
        style.configure("Sub.TLabel", font=("Microsoft YaHei UI", 10), foreground="#5f6b7a", background="#f4f7fb")
        style.configure("Card.TFrame", background="#ffffff")
        style.configure("Card.TLabel", background="#ffffff", font=("Microsoft YaHei UI", 10))
        style.configure("Hint.TLabel", background="#ffffff", foreground="#64748b", font=("Microsoft YaHei UI", 9))
        style.configure("Primary.TButton", font=("Microsoft YaHei UI", 11, "bold"), padding=(18, 10))
        style.configure("Treeview", font=("Microsoft YaHei UI", 9), rowheight=31)
        style.configure("Treeview.Heading", font=("Microsoft YaHei UI", 9, "bold"))

    def _build_ui(self) -> None:
        header = ttk.Frame(self, padding=(28, 22, 28, 10))
        header.pack(fill=X)
        ttk.Label(header, text="视频相似度离线实验室", style="Title.TLabel").pack(anchor="w")
        ttk.Label(
            header,
            text="研究固定画面变换对基础相似度算法的影响；全程离线，不连接任何直播平台。",
            style="Sub.TLabel",
        ).pack(anchor="w", pady=(5, 0))

        input_card = ttk.Frame(self, style="Card.TFrame", padding=20)
        input_card.pack(fill=X, padx=28, pady=(8, 10))
        self._path_row(input_card, "源视频", self.video_var, self._choose_video, 0)
        self._path_row(input_card, "报告目录", self.output_var, self._choose_output, 1)

        options = ttk.Frame(input_card, style="Card.TFrame")
        options.grid(row=2, column=1, sticky="w", pady=(12, 0))
        ttk.Label(options, text="分析时长（秒）", style="Card.TLabel").pack(side=LEFT)
        ttk.Spinbox(options, from_=10, to=180, increment=10, width=8, textvariable=self.seconds_var).pack(side=LEFT, padx=(10, 18))
        ttk.Label(options, text="每秒采样 2 帧；只生成报告和静态预览，不输出变换视频。", style="Hint.TLabel").pack(side=LEFT)
        input_card.columnconfigure(1, weight=1)

        action_row = ttk.Frame(self, padding=(28, 2, 28, 10))
        action_row.pack(fill=X)
        self.run_button = ttk.Button(action_row, text="开始离线分析", style="Primary.TButton", command=self._start)
        self.run_button.pack(side=LEFT)
        self.open_button = ttk.Button(action_row, text="打开 HTML 报告", command=self._open_report, state="disabled")
        self.open_button.pack(side=LEFT, padx=(10, 0))
        ttk.Label(action_row, textvariable=self.status_var, style="Sub.TLabel").pack(side=RIGHT)

        progress = ttk.Progressbar(self, variable=self.progress_var, maximum=100)
        progress.pack(fill=X, padx=28, pady=(0, 12))

        result_card = ttk.Frame(self, style="Card.TFrame", padding=18)
        result_card.pack(fill=BOTH, expand=True, padx=28, pady=(0, 14))
        ttk.Label(result_card, text="相似度结果（越高表示本工具认为越相似）", style="Card.TLabel").pack(anchor="w", pady=(0, 10))

        columns = ("variant", "ssim", "phash", "flip", "vector", "audio")
        self.tree = ttk.Treeview(result_card, columns=columns, show="headings", height=8)
        headings = {
            "variant": "固定实验变换",
            "ssim": "SSIM",
            "phash": "pHash",
            "flip": "翻转归一 pHash",
            "vector": "视觉向量",
            "audio": "音频指纹",
        }
        widths = {"variant": 240, "ssim": 95, "phash": 95, "flip": 130, "vector": 105, "audio": 105}
        for column in columns:
            self.tree.heading(column, text=headings[column])
            self.tree.column(column, width=widths[column], anchor="center")
        self.tree.column("variant", anchor="w")
        self.tree.pack(fill=BOTH, expand=True)

        note = ttk.Label(
            result_card,
            text="说明：这些指标不是任何平台的模型或判定阈值。音频未修改时仍保持相同，用于观察多模态检测为何不会只依赖画面。",
            style="Hint.TLabel",
            wraplength=930,
        )
        note.pack(anchor="w", pady=(12, 0))

        footer = ttk.Label(
            self,
            text="仅用于自有或已获授权素材的算法研究",
            style="Sub.TLabel",
        )
        footer.pack(pady=(0, 15))

    def _path_row(self, parent: ttk.Frame, label: str, variable: tk.StringVar, command, row: int) -> None:
        ttk.Label(parent, text=label, style="Card.TLabel").grid(row=row, column=0, sticky="w", padx=(0, 14), pady=6)
        ttk.Entry(parent, textvariable=variable).grid(row=row, column=1, sticky="ew", pady=6)
        ttk.Button(parent, text="选择…", command=command).grid(row=row, column=2, padx=(12, 0), pady=6)

    def _choose_video(self) -> None:
        selected = filedialog.askopenfilename(
            title="选择用于离线研究的视频",
            filetypes=[
                ("视频文件", "*.mp4 *.mov *.mkv *.flv *.avi *.webm *.m4v *.ts"),
                ("所有文件", "*.*"),
            ],
        )
        if not selected:
            return
        self.video_var.set(selected)
        if not self.output_var.get().strip():
            source = Path(selected)
            self.output_var.set(str(source.parent / f"{source.stem}_similarity_report"))

    def _choose_output(self) -> None:
        selected = filedialog.askdirectory(title="选择报告输出目录")
        if selected:
            self.output_var.set(selected)

    def _start(self) -> None:
        video = self.video_var.get().strip()
        output = self.output_var.get().strip()
        if not video or not Path(video).is_file():
            messagebox.showwarning("缺少视频", "请先选择一个有效的本地视频文件。", parent=self)
            return
        if not output:
            messagebox.showwarning("缺少目录", "请选择报告输出目录。", parent=self)
            return
        seconds = max(10, min(180, int(self.seconds_var.get())))
        self.seconds_var.set(seconds)
        self.run_button.configure(state="disabled")
        self.open_button.configure(state="disabled")
        self.progress_var.set(0)
        self.status_var.set("正在准备分析…")
        self._report_path = None
        for item in self.tree.get_children():
            self.tree.delete(item)

        threading.Thread(
            target=self._run_worker,
            args=(video, output, seconds),
            daemon=True,
        ).start()

    def _run_worker(self, video: str, output: str, seconds: int) -> None:
        try:
            def progress(value: float, message: str) -> None:
                self._events.put(("progress", (value, message)))

            results, files = analyze_video(video, output, seconds, 2.0, progress)
            self._events.put(("done", (results, files)))
        except Exception as exc:
            self._events.put(("error", (str(exc), traceback.format_exc())))

    def _drain_events(self) -> None:
        try:
            while True:
                kind, payload = self._events.get_nowait()
                if kind == "progress":
                    value, message = payload
                    self.progress_var.set(float(value) * 100)
                    self.status_var.set(str(message))
                elif kind == "done":
                    results, files = payload
                    self._show_results(results)
                    self._report_path = files["report"]
                    self.progress_var.set(100)
                    self.status_var.set("分析完成，报告已保存")
                    self.run_button.configure(state="normal")
                    self.open_button.configure(state="normal")
                elif kind == "error":
                    message, details = payload
                    self.run_button.configure(state="normal")
                    self.progress_var.set(0)
                    self.status_var.set("分析失败")
                    messagebox.showerror("分析失败", f"{message}\n\n{details}", parent=self)
        except queue.Empty:
            pass
        finally:
            self.after(100, self._drain_events)

    def _show_results(self, results: list[SimilarityResult]) -> None:
        for result in results:
            audio = "N/A" if result.audio_fingerprint is None else f"{result.audio_fingerprint * 100:.1f}%"
            self.tree.insert(
                "",
                END,
                values=(
                    result.label,
                    f"{result.ssim * 100:.1f}%",
                    f"{result.phash * 100:.1f}%",
                    f"{result.flip_aware_phash * 100:.1f}%",
                    f"{result.visual_vector * 100:.1f}%",
                    audio,
                ),
            )

    def _open_report(self) -> None:
        if self._report_path and Path(self._report_path).is_file():
            webbrowser.open(Path(self._report_path).as_uri())


def _self_test() -> int:
    try:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "self_test.avi"
            writer = cv2.VideoWriter(
                str(source),
                cv2.VideoWriter_fourcc(*"MJPG"),
                10.0,
                (160, 90),
            )
            if not writer.isOpened():
                return 21
            for index in range(20):
                frame = np.zeros((90, 160, 3), dtype=np.uint8)
                cv2.circle(frame, (25 + index * 4, 45), 18, (30, 180, 240), -1)
                writer.write(frame)
            writer.release()
            results, files = analyze_video(
                str(source),
                str(root / "report"),
                max_seconds=2,
                sample_fps=2,
            )
            if len(results) != 4:
                return 22
            if not all(Path(value).is_file() for value in files.values()):
                return 23
        return 0
    except Exception:
        return 29


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        raise SystemExit(_self_test())
    SimilarityLab().mainloop()
