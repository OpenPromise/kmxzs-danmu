import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { authStorage } from '../api/http';
import { login as apiLogin, logout as apiLogout, fetchMe } from '../api';
import type { UserInfo } from '../types';

interface AuthContextValue {
  user: UserInfo | null;
  loading: boolean;
  login: (username: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  refreshUser: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<UserInfo | null>(() => authStorage.getUser());
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // 启动时若持有 access token，则拉取 /me 刷新本地用户信息。
    // 若 token 已过期，http 拦截器会自动用 refresh 刷新并重试；刷新失败会跳登录页。
    if (authStorage.getAccess()) {
      fetchMe()
        .then(setUser)
        .catch(() => {
          /* 401 已在拦截器处理 */
        })
        .finally(() => setLoading(false));
    } else {
      setLoading(false);
    }
  }, []);

  const login = async (username: string, password: string) => {
    const u = await apiLogin(username, password);
    setUser(u);
  };

  const logout = async () => {
    await apiLogout();
    setUser(null);
  };

  const refreshUser = async () => {
    const u = await fetchMe();
    setUser(u);
  };

  return (
    <AuthContext.Provider value={{ user, loading, login, logout, refreshUser }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth 必须在 AuthProvider 内使用');
  return ctx;
}
