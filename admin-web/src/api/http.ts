import axios, { AxiosRequestConfig } from 'axios';
import type { UserInfo } from '../types';

const TOKEN_KEY = 'kmxzs_access_token';
const REFRESH_KEY = 'kmxzs_refresh_token';
const USER_KEY = 'kmxzs_user';

export class ApiError extends Error {
  code: number;
  constructor(code: number, message: string) {
    super(message);
    this.code = code;
    this.name = 'ApiError';
  }
}

/** 本地令牌 / 用户信息存取。 */
export const authStorage = {
  getAccess: () => localStorage.getItem(TOKEN_KEY) || '',
  getRefresh: () => localStorage.getItem(REFRESH_KEY) || '',
  setTokens: (access: string, refresh: string) => {
    localStorage.setItem(TOKEN_KEY, access);
    localStorage.setItem(REFRESH_KEY, refresh);
  },
  getUser: (): UserInfo | null => {
    try {
      const raw = localStorage.getItem(USER_KEY);
      return raw ? (JSON.parse(raw) as UserInfo) : null;
    } catch {
      return null;
    }
  },
  setUser: (u: UserInfo) => localStorage.setItem(USER_KEY, JSON.stringify(u)),
  clear: () => {
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(REFRESH_KEY);
    localStorage.removeItem(USER_KEY);
  },
};

export const http = axios.create({ timeout: 30000 });

http.interceptors.request.use((config) => {
  const token = authStorage.getAccess();
  if (token && !config.headers.Authorization) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

// ---------------------------------------------------------------------------
// access 过期 → 用 refresh 刷新一次并重放；刷新失败跳登录页
// ---------------------------------------------------------------------------
let isRefreshing = false;
let pendingQueue: Array<(token: string) => void> = [];

function toLogin() {
  authStorage.clear();
  const target = window.location.pathname.startsWith('/panel/')
    ? '/panel/login'
    : '/login';
  if (window.location.pathname !== target) {
    window.location.href = target;
  }
}

async function doRefresh(): Promise<string> {
  const refresh = authStorage.getRefresh();
  if (!refresh) throw new ApiError(401, '未登录');
  // 用裸 axios，避免再次进入响应拦截器递归刷新
  const resp = await axios.post('/api/auth/refresh', { refresh_token: refresh });
  const body = resp.data;
  if (!body || body.code !== 0 || !body.data) {
    throw new ApiError(body?.code || 401, body?.message || '刷新令牌失效');
  }
  const d = body.data;
  authStorage.setTokens(d.access_token, d.refresh_token);
  if (d.user) authStorage.setUser(d.user);
  return d.access_token as string;
}

http.interceptors.response.use(
  (resp) => resp,
  async (error) => {
    const config = error.config as (AxiosRequestConfig & { _retry?: boolean }) | undefined;
    const status = error.response?.status as number | undefined;
    const url = config?.url || '';
    const isAuthCall = url.includes('/auth/login') || url.includes('/auth/refresh');
    if (status === 401 && config && !config._retry && !isAuthCall) {
      if (isRefreshing) {
        return new Promise((resolve, reject) => {
          pendingQueue.push((token) => {
            config.headers = config.headers || {};
            config.headers.Authorization = `Bearer ${token}`;
            config._retry = true;
            resolve(http(config));
          });
        });
      }
      config._retry = true;
      isRefreshing = true;
      try {
        const token = await doRefresh();
        pendingQueue.forEach((cb) => cb(token));
        pendingQueue = [];
        config.headers = config.headers || {};
        config.headers.Authorization = `Bearer ${token}`;
        return http(config);
      } catch (e) {
        pendingQueue = [];
        toLogin();
        return Promise.reject(e);
      } finally {
        isRefreshing = false;
      }
    }
    return Promise.reject(error);
  }
);

/** 统一解包 {code, message, data} 信封；业务失败抛 ApiError。 */
export async function request<T>(config: AxiosRequestConfig): Promise<T> {
  try {
    const resp = await http.request(config);
    const body = resp.data;
    if (body && typeof body === 'object' && 'code' in body) {
      if (body.code === 0) return body.data as T;
      throw new ApiError(body.code, body.message || body.msg || '操作失败');
    }
    return body as T;
  } catch (err) {
    if (err instanceof ApiError) throw err;
    const e = err as { response?: { data?: { detail?: { code?: number; message?: string } } } };
    const detail = e.response?.data?.detail;
    if (detail && typeof detail.code === 'number') {
      throw new ApiError(detail.code, detail.message || '请求失败');
    }
    throw err;
  }
}

/** 带鉴权的 CSV 下载（后端用 Content-Disposition 指定文件名）。 */
export async function downloadCsv(config: AxiosRequestConfig): Promise<void> {
  const resp = await http.request({ ...config, responseType: 'blob' });
  const disposition = String(resp.headers['content-disposition'] || '');
  const match = disposition.match(/filename="?([^";]+)"?/i);
  const filename = match ? match[1] : 'download.csv';
  const url = URL.createObjectURL(resp.data as Blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
