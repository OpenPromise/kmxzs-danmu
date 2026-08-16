/** 前端 API 层：按当前登录角色自动选择 /api/admin 或 /api/reseller。 */
import { request, downloadCsv, authStorage } from './http';
import type {
  Account,
  AdminOverview,
  AgentUser,
  Card,
  Channel,
  Device,
  LogEntry,
  Paged,
  PublicConfig,
  ReleaseFile,
  ResellerOverview,
  UserInfo,
} from '../types';

function currentRole(): 'superadmin' | 'reseller' {
  return authStorage.getUser()?.role || 'superadmin';
}

function isSuper(): boolean {
  return currentRole() === 'superadmin';
}

// ---------------------------------------------------------------------------
// 认证
// ---------------------------------------------------------------------------
export async function login(username: string, password: string): Promise<UserInfo> {
  const data = await request<{
    access_token: string;
    refresh_token: string;
    user: UserInfo;
  }>({ method: 'POST', url: '/api/auth/login', data: { username, password } });
  authStorage.setTokens(data.access_token, data.refresh_token);
  authStorage.setUser(data.user);
  return data.user;
}

export async function fetchMe(): Promise<UserInfo> {
  const user = await request<UserInfo>({ method: 'GET', url: '/api/auth/me' });
  authStorage.setUser(user);
  return user;
}

export async function logout(): Promise<void> {
  const refresh = authStorage.getRefresh();
  try {
    if (refresh) {
      await request({ method: 'POST', url: '/api/auth/logout', data: { refresh_token: refresh } });
    }
  } finally {
    authStorage.clear();
  }
}

// ---------------------------------------------------------------------------
// 数据总览
// ---------------------------------------------------------------------------
export function getOverview(): Promise<AdminOverview | ResellerOverview> {
  if (isSuper()) {
    return request<AdminOverview>({ method: 'GET', url: '/api/admin/overview' });
  }
  return request<ResellerOverview>({ method: 'GET', url: '/api/reseller/overview' });
}

// ---------------------------------------------------------------------------
// 卡密
// ---------------------------------------------------------------------------
export interface CardListParams {
  q?: string;
  kind?: string;
  enabled?: number;
  channel_id?: number;
  current: number;
  pageSize: number;
}

export async function listCards(params: CardListParams): Promise<{ items: Card[]; total: number }> {
  if (isSuper()) {
    const data = await request<Paged<Card>>({
      method: 'GET',
      url: '/api/admin/cards',
      params: {
        q: params.q || undefined,
        kind: params.kind || undefined,
        enabled: params.enabled === undefined ? undefined : params.enabled,
        channel_id: params.channel_id || undefined,
        page: params.current,
        page_size: params.pageSize,
      },
    });
    return { items: data.items, total: data.total };
  }
  const data = await request<Card[]>({
    method: 'GET',
    url: '/api/reseller/cards',
    params: {
      q: params.q || undefined,
      kind: params.kind || undefined,
      enabled: params.enabled === undefined ? undefined : params.enabled,
    },
  });
  const start = (params.current - 1) * params.pageSize;
  return { items: data.slice(start, start + params.pageSize), total: data.length };
}

export interface CreateCardInput {
  code?: string;
  kind: string;
  hours: number;
  max_devices: number;
  note?: string;
  count: number;
  channel_id?: number;
}

export async function createCards(input: CreateCardInput): Promise<string[]> {
  const url = isSuper() ? '/api/admin/cards' : '/api/reseller/cards';
  const data = await request<{ cards: string[] }>({ method: 'POST', url, data: input });
  return data.cards;
}

export async function patchCard(
  code: string,
  body: { enabled?: boolean; note?: string; max_devices?: number; hours?: number }
): Promise<void> {
  const url = (isSuper() ? '/api/admin/cards' : '/api/reseller/cards') + `/${encodeURIComponent(code)}`;
  await request({ method: 'PATCH', url, data: body });
}

export async function deleteCard(code: string): Promise<void> {
  const url = (isSuper() ? '/api/admin/cards' : '/api/reseller/cards') + `/${encodeURIComponent(code)}`;
  await request({ method: 'DELETE', url });
}

export async function exportCards(params: {
  q?: string;
  kind?: string;
  enabled?: number;
  channel_id?: number;
}): Promise<void> {
  const url = isSuper() ? '/api/admin/cards/export' : '/api/reseller/cards/export';
  await downloadCsv({
    method: 'GET',
    url,
    params: {
      q: params.q || undefined,
      kind: params.kind || undefined,
      enabled: params.enabled === undefined ? undefined : params.enabled,
      channel_id: params.channel_id || undefined,
    },
  });
}

// ---------------------------------------------------------------------------
// 账号
// ---------------------------------------------------------------------------
export async function listAccounts(params: {
  q?: string;
  current: number;
  pageSize: number;
}): Promise<{ items: Account[]; total: number }> {
  if (isSuper()) {
    const data = await request<Paged<Account>>({
      method: 'GET',
      url: '/api/admin/accounts',
      params: { q: params.q || undefined, page: params.current, page_size: params.pageSize },
    });
    return { items: data.items, total: data.total };
  }
  const data = await request<Account[]>({ method: 'GET', url: '/api/reseller/accounts' });
  const start = (params.current - 1) * params.pageSize;
  return { items: data.slice(start, start + params.pageSize), total: data.length };
}

export async function extendAccount(card: string, hours: number): Promise<void> {
  await request({
    method: 'POST',
    url: `/api/admin/accounts/${encodeURIComponent(card)}/extend`,
    data: { hours },
  });
}

// ---------------------------------------------------------------------------
// 设备
// ---------------------------------------------------------------------------
export async function listDevices(params: {
  q?: string;
  current: number;
  pageSize: number;
}): Promise<{ items: Device[]; total: number }> {
  if (isSuper()) {
    const data = await request<Paged<Device>>({
      method: 'GET',
      url: '/api/admin/devices',
      params: { q: params.q || undefined, page: params.current, page_size: params.pageSize },
    });
    return { items: data.items, total: data.total };
  }
  const data = await request<Device[]>({ method: 'GET', url: '/api/reseller/devices' });
  const start = (params.current - 1) * params.pageSize;
  return { items: data.slice(start, start + params.pageSize), total: data.length };
}

export async function unbindDevice(id: number): Promise<void> {
  const url = (isSuper() ? '/api/admin' : '/api/reseller') + `/devices/${id}`;
  await request({ method: 'DELETE', url });
}

// ---------------------------------------------------------------------------
// 审计日志
// ---------------------------------------------------------------------------
export async function listLogs(params: {
  action?: string;
  current: number;
  pageSize: number;
}): Promise<{ items: LogEntry[]; total: number }> {
  if (isSuper()) {
    const data = await request<Paged<LogEntry>>({
      method: 'GET',
      url: '/api/admin/logs',
      params: { action: params.action || undefined, page: params.current, page_size: params.pageSize },
    });
    return { items: data.items, total: data.total };
  }
  const limit = Math.max(1, Math.min(params.current * params.pageSize, 500));
  const data = await request<LogEntry[]>({
    method: 'GET',
    url: '/api/reseller/logs',
    params: { limit },
  });
  const start = (params.current - 1) * params.pageSize;
  return { items: data.slice(start, start + params.pageSize), total: data.length };
}

// ---------------------------------------------------------------------------
// 渠道 / 代理（超管）
// ---------------------------------------------------------------------------
export function listChannels(): Promise<Channel[]> {
  return request<Channel[]>({ method: 'GET', url: '/api/admin/channels' });
}

export async function createChannel(code: string, name: string): Promise<void> {
  await request({ method: 'POST', url: '/api/admin/channels', data: { code, name } });
}

export async function patchChannel(
  id: number,
  body: { name?: string; status?: number }
): Promise<void> {
  await request({ method: 'PATCH', url: `/api/admin/channels/${id}`, data: body });
}

export function listUsers(): Promise<AgentUser[]> {
  return request<AgentUser[]>({ method: 'GET', url: '/api/admin/users' });
}

export async function createUser(input: {
  username: string;
  password: string;
  channel_id?: number;
  card_quota: number;
  role?: string;
}): Promise<void> {
  await request({ method: 'POST', url: '/api/admin/users', data: input });
}

export async function patchUser(
  id: number,
  body: { password?: string; channel_id?: number; card_quota?: number; enabled?: boolean }
): Promise<void> {
  await request({ method: 'PATCH', url: `/api/admin/users/${id}`, data: body });
}

// ---------------------------------------------------------------------------
// 客户端配置 / 安装包发布（超管）
// ---------------------------------------------------------------------------
export function getSettings(): Promise<{
  settings: Record<string, { value: string; updatedAt: string }>;
  public: PublicConfig;
}> {
  return request({ method: 'GET', url: '/api/admin/settings' });
}

export function updateSettings(body: {
  notice?: string;
  client_version?: string;
  force_update?: boolean;
  min_client_version?: string;
}): Promise<PublicConfig> {
  return request({ method: 'PUT', url: '/api/admin/settings', data: body });
}

export function listReleases(): Promise<{ files: ReleaseFile[]; latestUrl: string }> {
  return request({ method: 'GET', url: '/api/admin/releases' });
}

export async function uploadRelease(
  file: File,
  version: string,
  forceUpdate: boolean
): Promise<{ version: string; size: number; download: string }> {
  const form = new FormData();
  form.append('file', file);
  form.append('version', version);
  form.append('force_update', forceUpdate ? '1' : '0');
  return request({
    method: 'POST',
    url: '/api/admin/releases',
    data: form,
  });
}
