/* [E] hook.dll — IDA 逆向结论 (Keroro Software 通用钩子库)
 *
 * 导出均为 C++ 成员函数桩: lea rcx,[global_obj]; jmp Method
 * 五个全局对象:
 *   0x8120  Capture   — RAW socket 抓包
 *   0x81c0  Proxy     — 本地 HTTP 代理 (302 / 改包)
 *   0x8440  Pipe      — 命名管道监视
 *   0x1087d0 Scan     — 跨进程 VirtualQueryEx+ReadProcessMemory 扫串
 *   0x108840 ApiHook  — VirtualProtect inline hook (wininet 等)
 *
 * 无 CreateFileMapping / 无 KSStreamCode / 无 crypto_* 导出。
 * 早期 DLL 注入、进程内存扫码与共享内存抓码路径均已随
 * 「平台解析 + OBS 拉流」方案下线。
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* 无参 — CreateRemoteThread(export, NULL) 可用 */
__declspec(dllexport) int Hook_InitApiHook(void);
__declspec(dllexport) int Hook_HookWinInet(void);
__declspec(dllexport) int Hook_HookCrypto(void);
__declspec(dllexport) int Hook_HookFileSystem(void);
__declspec(dllexport) int Hook_HookRegistry(void);
__declspec(dllexport) int Hook_StartLogging(void);
__declspec(dllexport) int Hook_GetCallCount(void);
__declspec(dllexport) int Hook_GetCapturedCount(void);
__declspec(dllexport) int Hook_GetMatchCount(void);
__declspec(dllexport) int Hook_StartCapture(void);   /* 需先 InitCapture */
__declspec(dllexport) int Hook_StopCapture(void);
__declspec(dllexport) int Hook_StartMonitor(void);   /* 需先 InitPipe */
__declspec(dllexport) int Hook_StopMonitor(void);
__declspec(dllexport) int Hook_StartProxy(void);     /* 需先 InitProxy */
__declspec(dllexport) int Hook_StopProxy(void);
__declspec(dllexport) int Hook_ResumeTarget(void);
__declspec(dllexport) int Hook_SuspendTarget(void);

/* 有参 — 不能直接用空 CreateRemoteThread */
__declspec(dllexport) int Hook_InitCapture(const char* bind_ip, int promiscuous);
__declspec(dllexport) int Hook_InitPipe(const char* pipe_name);
__declspec(dllexport) int Hook_InitProxy(unsigned short port);
__declspec(dllexport) int Hook_InitScan(unsigned int pid);
__declspec(dllexport) int Hook_ScanString(const char* pattern);
__declspec(dllexport) int Hook_InjectCert(void* a, void* b);
__declspec(dllexport) int Hook_PatchAll(void* a, int b);
__declspec(dllexport) int Hook_PatchMemory(void* a, void* b, int c);
__declspec(dllexport) int Hook_ClonePipe(const char* name);
__declspec(dllexport) int Hook_RedirectPipe(const char* name);

/* crypto_* 在 app.so 字符串中有 FFI 名，但本 DLL 导出表不存在 */

#ifdef __cplusplus
}
#endif
