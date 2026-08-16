import { useEffect, useState } from 'react';
import { App, Button, Form, Input, Modal, Space, Table, Tag } from 'antd';
import { PlusOutlined } from '@ant-design/icons';
import { createChannel, listChannels, patchChannel } from '../api';
import { formatTime } from '../utils/format';
import type { Channel } from '../types';

export default function Channels() {
  const { message, modal } = App.useApp();
  const [data, setData] = useState<Channel[]>([]);
  const [loading, setLoading] = useState(false);
  const [createOpen, setCreateOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [renameTarget, setRenameTarget] = useState<Channel | null>(null);
  const [createForm] = Form.useForm();
  const [renameForm] = Form.useForm();

  const load = async () => {
    setLoading(true);
    try {
      setData(await listChannels());
    } catch (e) {
      message.error((e as Error)?.message || '加载渠道失败');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
  }, []);

  const onCreate = async () => {
    const v = await createForm.validateFields();
    setCreating(true);
    try {
      await createChannel(v.code.trim(), v.name.trim());
      message.success('渠道已创建');
      setCreateOpen(false);
      createForm.resetFields();
      load();
    } catch (e) {
      message.error((e as Error)?.message || '创建失败');
    } finally {
      setCreating(false);
    }
  };

  const onToggle = (ch: Channel) => {
    const next = ch.status === 1 ? 0 : 1;
    modal.confirm({
      title: next === 0 ? '停用渠道' : '启用渠道',
      content:
        next === 0
          ? `停用后该渠道代理将无法登录与发卡（历史数据保留），确认停用「${ch.name}」？`
          : `确认启用「${ch.name}」？`,
      okText: '确认',
      cancelText: '取消',
      okButtonProps: { danger: next === 0 },
      onOk: async () => {
        await patchChannel(ch.id, { status: next });
        message.success('已更新');
        load();
      },
    });
  };

  const openRename = (ch: Channel) => {
    setRenameTarget(ch);
    renameForm.setFieldsValue({ name: ch.name });
  };

  const onRename = async () => {
    if (!renameTarget) return;
    const v = await renameForm.validateFields();
    try {
      await patchChannel(renameTarget.id, { name: v.name.trim() });
      message.success('已重命名');
      setRenameTarget(null);
      load();
    } catch (e) {
      message.error((e as Error)?.message || '重命名失败');
    }
  };

  const columns = [
    { title: 'ID', dataIndex: 'id', width: 70 },
    { title: '编码', dataIndex: 'code', width: 150 },
    { title: '名称', dataIndex: 'name', width: 200 },
    { title: '卡密数', dataIndex: 'card_count', width: 100 },
    { title: '代理数', dataIndex: 'agent_count', width: 100 },
    {
      title: '状态',
      dataIndex: 'status',
      width: 100,
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
      width: 160,
      render: (_: unknown, r: Channel) => (
        <Space>
          <a onClick={() => openRename(r)}>重命名</a>
          {r.status === 1 ? (
            <a style={{ color: '#ff4d4f' }} onClick={() => onToggle(r)}>
              停用
            </a>
          ) : (
            <a style={{ color: '#52c41a' }} onClick={() => onToggle(r)}>
              启用
            </a>
          )}
        </Space>
      ),
    },
  ];

  return (
    <>
      <Table<Channel>
        rowKey="id"
        loading={loading}
        dataSource={data}
        columns={columns}
        size="middle"
        title={() => (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span>渠道管理（代理数据隔离维度）</span>
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateOpen(true)}>
              新建渠道
            </Button>
          </div>
        )}
        pagination={false}
      />

      <Modal
        title="新建渠道"
        open={createOpen}
        onOk={onCreate}
        confirmLoading={creating}
        onCancel={() => {
          setCreateOpen(false);
          createForm.resetFields();
        }}
        width={420}
      >
        <Form form={createForm} layout="vertical">
          <Form.Item
            name="code"
            label="渠道编码"
            rules={[{ required: true, message: '请输入渠道编码' }]}
          >
            <Input placeholder="如 CH-001" maxLength={50} />
          </Form.Item>
          <Form.Item
            name="name"
            label="渠道名称"
            rules={[{ required: true, message: '请输入渠道名称' }]}
          >
            <Input placeholder="如 华东代理" maxLength={100} />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        title={`重命名渠道：${renameTarget?.code ?? ''}`}
        open={!!renameTarget}
        onOk={onRename}
        onCancel={() => setRenameTarget(null)}
        width={420}
      >
        <Form form={renameForm} layout="vertical">
          <Form.Item name="name" label="渠道名称" rules={[{ required: true, message: '请输入渠道名称' }]}>
            <Input maxLength={100} />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}
