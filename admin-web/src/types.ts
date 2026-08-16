/** 前后端共享的数据类型。 */

export type Role = 'superadmin' | 'reseller';

export interface UserInfo {
  id: number;
  username: string;
  role: Role;
  channel_id: number | null;
  card_quota: number;
  enabled: boolean;
  quota_used: number;
  created_at: string;
}

export interface Card {
  code: string;
  kind: 'login' | 'topup';
  hours: number;
  max_devices: number;
  enabled: number;
  note: string | null;
  created_at: string;
  channel_id: number | null;
  channel_name: string | null;
  account_expires_at: string | null;
  device_count: number;
  topup_used: number | null;
}

export interface Account {
  card: string;
  expires_at: string;
  created_at: string;
  updated_at: string;
  device_count: number;
  channel_name?: string | null;
}

export interface Device {
  id: number;
  card: string;
  device_id: string;
  name: string | null;
  bound_at: string;
  channel_name?: string | null;
}

export interface Channel {
  id: number;
  code: string;
  name: string;
  owner_user_id: number | null;
  status: number;
  created_at: string;
  card_count: number;
  agent_count: number;
}

export interface AgentUser {
  id: number;
  username: string;
  role: Role;
  channel_id: number | null;
  channel_name: string | null;
  card_quota: number;
  quota_used: number;
  enabled: number;
  created_at: string;
}

export interface LogEntry {
  id: number;
  created_at: string;
  actor: string;
  action: string;
  target: string | null;
  detail: string | null;
  ip: string | null;
  ok: number;
}

export interface AdminOverview {
  cardsTotal: number;
  cardsLoginEnabled: number;
  cardsTopupEnabled: number;
  accounts: number;
  devices: number;
  sessions: number;
  topupUsed: number;
  users: number;
  resellers: number;
  channels: Channel[];
  noteChannels: { name: string; count: number }[];
}

export interface ResellerOverview {
  cardsTotal: number;
  cardsLoginEnabled: number;
  cardsTopupEnabled: number;
  accounts: number;
  devices: number;
  quota: number;
  quota_used: number;
}

export interface PublicConfig {
  notice: string;
  version: string;
  download: string;
  downloadSize: number;
  force: boolean;
  minVersion: string;
  serverVersion: string;
  seedDemo: boolean;
}

export interface Paged<T> {
  items: T[];
  total: number;
  page: number;
  page_size: number;
}

export interface ReleaseFile {
  name: string;
  size: number;
  updatedAt: string;
  url: string;
}
