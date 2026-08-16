import { useRef } from 'react';
import { App, Space, Typography } from 'antd';
import { ActionType, ProColumns, ProTable } from '@ant-design/pro-components';
import { listDevices, unbindDevice } from '../api';
import { useAuth } from '../context/AuthContext';
import CopyButton from '../components/CopyButton';
import { formatTime } from '../utils/format';
import type { Device } from '../types';

export default function Devices() {
  const { user } = useAuth();
  const isSuper = user?.role === 'superadmin';
  const { message, modal } = App.useApp();
  const actionRef = useRef<ActionType>();

  const confirmUnbind = (r: Device) => {
    modal.confirm({
      title: '解绑设备',
      content: `确认解绑设备「${r.device_id}」（卡密 ${r.card}）？客户端将需要重新登录。`,
      okText: '解绑',
      cancelText: '取消',
      okButtonProps: { danger: true },
      onOk: async () => {
        await unbindDevice(r.id);
        message.success('已解绑');
        actionRef.current?.reload();
      },
    });
  };

  const request = async (p: Record<string, unknown>) => {
    const { items, total } = await listDevices({
      q: (p.q as string) || undefined,
      current: Number(p.current ?? 1),
      pageSize: Number(p.pageSize ?? 20),
    });
    return { data: items, total, success: true };
  };

  const columns: ProColumns<Device>[] = [
    {
      title: '搜索',
      dataIndex: 'q',
      hideInTable: true,
      valueType: 'text',
      fieldProps: { placeholder: '设备ID / 卡密' },
    },
    { title: 'ID', dataIndex: 'id', search: false, width: 80 },
    {
      title: '卡密',
      dataIndex: 'card',
      search: false,
      ellipsis: true,
      width: 230,
      render: (_, r) => (
        <Space size={2}>
          <Typography.Text style={{ fontFamily: 'monospace' }}>{r.card}</Typography.Text>
          <CopyButton text={r.card} />
        </Space>
      ),
    },
    {
      title: '设备ID',
      dataIndex: 'device_id',
      search: false,
      ellipsis: true,
      width: 200,
      render: (_, r) => (
        <Space size={2}>
          <Typography.Text code>{r.device_id}</Typography.Text>
          <CopyButton text={r.device_id} />
        </Space>
      ),
    },
    { title: '设备名', dataIndex: 'name', search: false, ellipsis: true, render: (_, r) => r.name || r.device_id },
    ...(isSuper
      ? [
          {
            title: '渠道',
            dataIndex: 'channel_name' as const,
            search: false,
            width: 140,
            render: (_: unknown, r: Device) => r.channel_name || '-',
          },
        ]
      : []),
    { title: '绑定时间', dataIndex: 'bound_at', search: false, width: 180, render: (_, r) => formatTime(r.bound_at) },
    {
      title: '操作',
      valueType: 'option',
      width: 90,
      render: (_, r) => (
        <a style={{ color: '#ff4d4f' }} onClick={() => confirmUnbind(r)}>
          解绑
        </a>
      ),
    },
  ];

  return (
    <ProTable<Device>
      headerTitle="设备管理"
      actionRef={actionRef}
      rowKey="id"
      columns={columns}
      request={request}
      search={{ labelWidth: 'auto' }}
      pagination={{ pageSize: 20, showSizeChanger: true, showTotal: (t) => `共 ${t} 条` }}
      scroll={{ x: 1100 }}
    />
  );
}
