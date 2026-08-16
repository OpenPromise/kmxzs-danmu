import { useRef } from 'react';
import { Tag, Tooltip, Typography } from 'antd';
import { ActionType, ProColumns, ProTable } from '@ant-design/pro-components';
import { listLogs } from '../api';
import { useAuth } from '../context/AuthContext';
import { formatTime, parseDetail } from '../utils/format';
import type { LogEntry } from '../types';

const ACTION_MAP: Record<string, string> = {
  admin_create_cards: '超管发卡',
  admin_patch_card: '修改卡密',
  admin_delete_card: '删除卡密',
  admin_extend_account: '账号续期',
  admin_unbind_device: '解绑设备',
  admin_export_cards: '导出卡密',
  admin_create_channel: '新建渠道',
  admin_patch_channel: '修改渠道',
  admin_create_user: '新建代理',
  admin_patch_user: '修改代理',
  admin_update_settings: '更新客户端配置',
  admin_upload_release: '发布安装包',
  reseller_create_cards: '代理发卡',
  reseller_patch_card: '代理改卡',
  reseller_delete_card: '代理删卡',
  reseller_unbind_device: '代理解绑设备',
  reseller_export_cards: '代理导出',
  login_ok: '客户端登录',
  topup_ok: '客户端充值',
};

export default function Logs() {
  const { user } = useAuth();
  const isSuper = user?.role === 'superadmin';
  const actionRef = useRef<ActionType>();

  const request = async (p: Record<string, unknown>) => {
    const { items, total } = await listLogs({
      action: (p.action as string) || undefined,
      current: Number(p.current ?? 1),
      pageSize: Number(p.pageSize ?? 20),
    });
    return { data: items, total, success: true };
  };

  const columns: ProColumns<LogEntry>[] = [
    { title: '时间', dataIndex: 'created_at', search: false, width: 180, render: (_, r) => formatTime(r.created_at) },
    { title: '操作者', dataIndex: 'actor', search: false, width: 130 },
    {
      title: '动作',
      dataIndex: 'action',
      width: 150,
      valueType: 'select',
      valueEnum: isSuper
        ? Object.fromEntries(Object.entries(ACTION_MAP).map(([k, v]) => [k, v]))
        : undefined,
      search: isSuper ? undefined : false,
      render: (_, r) => {
        const label = ACTION_MAP[r.action] || r.action;
        return <Tag>{label}</Tag>;
      },
    },
    {
      title: '目标',
      dataIndex: 'target',
      search: false,
      ellipsis: true,
      width: 180,
      render: (_, r) => r.target || '-',
    },
    {
      title: '详情',
      dataIndex: 'detail',
      search: false,
      ellipsis: true,
      width: 220,
      render: (_, r) => {
        const text = parseDetail(r.detail);
        if (!text) return '-';
        return (
          <Tooltip title={text}>
            <Typography.Text style={{ fontFamily: 'monospace' }} ellipsis>
              {text}
            </Typography.Text>
          </Tooltip>
        );
      },
    },
    { title: 'IP', dataIndex: 'ip', search: false, width: 120, render: (_, r) => r.ip || '-' },
    {
      title: '结果',
      dataIndex: 'ok',
      search: false,
      width: 80,
      render: (_, r) =>
        r.ok === 1 ? <Tag color="green">成功</Tag> : <Tag color="red">失败</Tag>,
    },
  ];

  return (
    <ProTable<LogEntry>
      headerTitle={isSuper ? '审计日志' : '操作日志'}
      actionRef={actionRef}
      rowKey="id"
      columns={columns}
      request={request}
      search={isSuper ? { labelWidth: 'auto' } : false}
      pagination={{ pageSize: 20, showSizeChanger: true, showTotal: (t) => `共 ${t} 条` }}
      scroll={{ x: 1100 }}
    />
  );
}
