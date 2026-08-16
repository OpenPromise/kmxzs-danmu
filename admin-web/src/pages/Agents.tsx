import { useEffect, useState } from 'react';
import { App, Button, Form, Input, InputNumber, Modal, Select, Space, Table, Tag } from 'antd';
import { PlusOutlined } from '@ant-design/icons';
import { createUser, listChannels, listUsers, patchUser } from '../api';
import { formatTime } from '../utils/format';
import type { AgentUser, Channel } from '../types';

export default function Agents() {
  const { message, modal } = App.useApp();
  const [data, setData] = useState<AgentUser[]>([]);
  const [loading, setLoading] = useState(false);
  const [channelOptions, setChannelOptions] = useState<{ label: string; value: number }[]>([]);

  const [createOpen, setCreateOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [createForm] = Form.useForm();

  const [quotaTarget, setQuotaTarget] = useState<AgentUser | null>(null);
  const [quotaForm] = Form.useForm();

  const [pwdTarget, setPwdTarget] = useState<AgentUser | null>(null);
  const [pwdForm] = Form.useForm();

  const load = async () => {
    setLoading(true);
    try {
      setData(await listUsers());
    } catch (e) {
      message.error((e as Error)?.message || '加载代理失败');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    listChannels()
      .then((chs: Channel[]) =>
        setChannelOptions(chs.map((c) => ({ label: `${c.code} ${c.name}`, value: c.id })))
      )
      .catch(() => undefined);
  }, []);

  const onCreate = async () => {
    const v = await createForm.validateFields();
    setCreating(true);
    try {
      await createUser({
        username: v.username.trim(),
        password: v.password,
        channel_id: v.channel_id,
        card_quota: v.card_quota ?? 0,
        role: 'reseller',
      });
      message.success('代理账号已创建');
      setCreateOpen(false);
      createForm.resetFields();
      load();
    } catch (e) {
      message.error((e as Error)?.message || '创建失败');
    } finally {
      setCreating(false);
    }
  };

  const onSetQuota = async () => {
    if (!quotaTarget) return;
    const v = await quotaForm.validateFields();
    try {
      await patchUser(quotaTarget.id, { card_quota: v.card_quota });
      message.success('配额已更新');
      setQuotaTarget(null);
      load();
    } catch (e) {
      message.error((e as Error)?.message || '更新失败');
    }
  };

  const onResetPassword = async () => {
    if (!pwdTarget) return;
    const v = await pwdForm.validateFields();
    try {
      await patchUser(pwdTarget.id, { password: v.password });
      message.success('密码已重置');
      setPwdTarget(null);
      pwdForm.resetFields();
    } catch (e) {
      message.error((e as Error)?.message || '重置失败');
    }
  };

  const toggleEnabled = (r: AgentUser) => {
    const next = r.enabled === 1 ? false : true;
    modal.confirm({
      title: next ? '启用账号' : '停用账号',
      content: next
        ? `确认启用代理「${r.username}」？`
        : `停用后代理「${r.username}」将无法登录，确认停用？`,
      okText: '确认',
      cancelText: '取消',
      okButtonProps: { danger: !next },
      onOk: async () => {
        await patchUser(r.id, { enabled: next });
        message.success('已更新');
        load();
      },
    });
  };

  const columns = [
    { title: 'ID', dataIndex: 'id', width: 70 },
    { title: '用户名', dataIndex: 'username', width: 140 },
    {
      title: '角色',
      dataIndex: 'role',
      width: 90,
      render: (v: string) =>
        v === 'superadmin' ? <Tag color="gold">超管</Tag> : <Tag>代理</Tag>,
    },
    { title: '渠道', dataIndex: 'channel_name', width: 160, render: (v: string) => v || '-' },
    { title: '配额', dataIndex: 'card_quota', width: 90 },
    { title: '已用', dataIndex: 'quota_used', width: 90 },
    {
      title: '状态',
      dataIndex: 'enabled',
      width: 90,
      render: (v: number) =>
        v === 1 ? <Tag color="green">启用</Tag> : <Tag color="red">停用</Tag>,
    },
    {
      title: '创建时间',
      dataIndex: 'created_at',
      width: 180,
      render: (v: string) => formatTime(v),
    },
    {
      title: '操作',
      key: 'action',
      width: 200,
      render: (_: unknown, r: AgentUser) => (
        <Space size={8} wrap>
          <a onClick={() => { setQuotaTarget(r); quotaForm.setFieldsValue({ card_quota: r.card_quota }); }}>
            设配额
          </a>
          <a onClick={() => setPwdTarget(r)}>重置密码</a>
          {r.role !== 'superadmin' &&
            (r.enabled === 1 ? (
              <a style={{ color: '#ff4d4f' }} onClick={() => toggleEnabled(r)}>
                停用
              </a>
            ) : (
              <a style={{ color: '#52c41a' }} onClick={() => toggleEnabled(r)}>
                启用
              </a>
            ))}
        </Space>
      ),
    },
  ];

  return (
    <>
      <Table<AgentUser>
        rowKey="id"
        loading={loading}
        dataSource={data}
        columns={columns}
        size="middle"
        title={() => (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span>代理账号管理</span>
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateOpen(true)}>
              新建代理
            </Button>
          </div>
        )}
        pagination={false}
      />

      <Modal
        title="新建代理账号"
        open={createOpen}
        onOk={onCreate}
        confirmLoading={creating}
        onCancel={() => {
          setCreateOpen(false);
          createForm.resetFields();
        }}
        width={440}
      >
        <Form form={createForm} layout="vertical" initialValues={{ card_quota: 0 }}>
          <Form.Item name="username" label="用户名" rules={[{ required: true, min: 3, message: '至少 3 个字符' }]}>
            <Input placeholder="代理登录名" maxLength={50} />
          </Form.Item>
          <Form.Item name="password" label="初始密码" rules={[{ required: true, min: 8, message: '至少 8 个字符' }]}>
            <Input.Password placeholder="至少 8 个字符" />
          </Form.Item>
          <Form.Item name="channel_id" label="绑定渠道" rules={[{ required: true, message: '请选择渠道' }]}>
            <Select showSearch options={channelOptions} optionFilterProp="label" placeholder="代理只能管理该渠道" />
          </Form.Item>
          <Form.Item name="card_quota" label="发卡配额" extra="登录卡可创建数量上限，充值卡不占配额">
            <InputNumber min={0} max={1000000} style={{ width: '100%' }} />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title={`设置配额：${quotaTarget?.username ?? ''}`}
        open={!!quotaTarget}
        onOk={onSetQuota}
        onCancel={() => setQuotaTarget(null)}
        width={400}
      >
        <Form form={quotaForm} layout="vertical">
          <Form.Item name="card_quota" label="发卡配额" rules={[{ required: true }]}>
            <InputNumber min={0} max={1000000} style={{ width: '100%' }} />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title={`重置密码：${pwdTarget?.username ?? ''}`}
        open={!!pwdTarget}
        onOk={onResetPassword}
        onCancel={() => setPwdTarget(null)}
        width={400}
      >
        <Form form={pwdForm} layout="vertical">
          <Form.Item name="password" label="新密码" rules={[{ required: true, min: 8, message: '至少 8 个字符' }]}>
            <Input.Password placeholder="至少 8 个字符" />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}
