import { useRef, useState } from 'react';
import { App, Form, InputNumber, Modal, Space, Typography } from 'antd';
import { ActionType, ProColumns, ProTable } from '@ant-design/pro-components';
import { extendAccount, listAccounts } from '../api';
import { useAuth } from '../context/AuthContext';
import CopyButton from '../components/CopyButton';
import { formatTime } from '../utils/format';
import type { Account } from '../types';

export default function Accounts() {
  const { user } = useAuth();
  const isSuper = user?.role === 'superadmin';
  const { message } = App.useApp();
  const actionRef = useRef<ActionType>();
  const [extendOpen, setExtendOpen] = useState(false);
  const [extendCard, setExtendCard] = useState<string>('');
  const [extending, setExtending] = useState(false);
  const [extendForm] = Form.useForm();

  const openExtend = (card: string) => {
    setExtendCard(card);
    extendForm.setFieldsValue({ hours: 24 });
    setExtendOpen(true);
  };

  const onExtend = async () => {
    const v = await extendForm.validateFields();
    setExtending(true);
    try {
      await extendAccount(extendCard, v.hours);
      message.success('续期成功');
      setExtendOpen(false);
      actionRef.current?.reload();
    } catch (e) {
      message.error((e as Error)?.message || '续期失败');
    } finally {
      setExtending(false);
    }
  };

  const request = async (p: Record<string, unknown>) => {
    const { items, total } = await listAccounts({
      q: (p.q as string) || undefined,
      current: Number(p.current ?? 1),
      pageSize: Number(p.pageSize ?? 20),
    });
    return { data: items, total, success: true };
  };

  const columns: ProColumns<Account>[] = [
    {
      title: '搜索',
      dataIndex: 'q',
      hideInTable: true,
      valueType: 'text',
      fieldProps: { placeholder: '卡密 / 渠道' },
    },
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
    ...(isSuper
      ? [
          {
            title: '渠道',
            dataIndex: 'channel_name' as const,
            search: false,
            width: 140,
            render: (_: unknown, r: Account) => r.channel_name || '-',
          },
        ]
      : []),
    { title: '到期时间', dataIndex: 'expires_at', search: false, width: 180, render: (_, r) => formatTime(r.expires_at) },
    { title: '更新时间', dataIndex: 'updated_at', search: false, width: 180, render: (_, r) => formatTime(r.updated_at) },
    { title: '设备数', dataIndex: 'device_count', search: false, width: 80 },
    {
      title: '创建时间',
      dataIndex: 'created_at',
      search: false,
      width: 180,
      render: (_, r) => formatTime(r.created_at),
    },
    ...(isSuper
      ? [
          {
            title: '操作',
            valueType: 'option' as const,
            width: 90,
            render: (_: unknown, r: Account) => (
              <a onClick={() => openExtend(r.card)}>续期</a>
            ),
          },
        ]
      : []),
  ];

  return (
    <>
      <ProTable<Account>
        headerTitle="账号管理"
        actionRef={actionRef}
        rowKey="card"
        columns={columns}
        request={request}
        search={{ labelWidth: 'auto' }}
        pagination={{ pageSize: 20, showSizeChanger: true, showTotal: (t) => `共 ${t} 条` }}
        scroll={{ x: 900 }}
      />

      <Modal
        title={`账号续期：${extendCard}`}
        open={extendOpen}
        onOk={onExtend}
        confirmLoading={extending}
        onCancel={() => setExtendOpen(false)}
        width={400}
      >
        <Form form={extendForm} layout="vertical">
          <Form.Item
            name="hours"
            label="增加时长（小时）"
            extra="负数表示扣减时长"
            rules={[{ required: true }]}
          >
            <InputNumber min={-24 * 365} max={24 * 3650} style={{ width: '100%' }} />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}
