import { useEffect, useRef, useState } from 'react';
import {
  Alert,
  App,
  Button,
  Form,
  Input,
  InputNumber,
  Modal,
  Radio,
  Select,
  Space,
  Tag,
  Typography,
} from 'antd';
import {
  DownloadOutlined,
  PlusOutlined,
  StopOutlined,
  PlayCircleOutlined,
} from '@ant-design/icons';
import { ActionType, ProColumns, ProTable } from '@ant-design/pro-components';
import {
  createCards,
  deleteCard,
  exportCards,
  listCards,
  listChannels,
  patchCard,
  type CardListParams,
} from '../api';
import { useAuth } from '../context/AuthContext';
import CopyButton from '../components/CopyButton';
import { formatTime } from '../utils/format';
import type { Card } from '../types';

export default function Cards() {
  const { user, refreshUser } = useAuth();
  const isSuper = user?.role === 'superadmin';
  const { message, modal } = App.useApp();
  const actionRef = useRef<ActionType>();
  const lastParams = useRef<CardListParams>({ current: 1, pageSize: 20 });

  const [createOpen, setCreateOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [channelOptions, setChannelOptions] = useState<{ label: string; value: number }[]>([]);
  const [createForm] = Form.useForm();

  useEffect(() => {
    if (isSuper) {
      listChannels()
        .then((chs) =>
          setChannelOptions(chs.map((c) => ({ label: `${c.code} ${c.name}`, value: c.id })))
        )
        .catch(() => undefined);
    }
  }, [isSuper]);

  const confirmDanger = (
    title: string,
    content: string,
    onOk: () => Promise<void>
  ) => {
    modal.confirm({
      title,
      content,
      okText: '确认',
      cancelText: '取消',
      okButtonProps: { danger: true },
      onOk,
    });
  };

  const onToggle = (r: Card, enabled: boolean) => {
    confirmDanger(
      enabled ? '启用卡密' : '停用卡密',
      `${enabled ? '启用' : '停用'}后，卡密「${r.code}」将${enabled ? '可' : '不可'}登录。`,
      async () => {
        await patchCard(r.code, { enabled });
        message.success(enabled ? '已启用' : '已停用');
        actionRef.current?.reload();
      }
    );
  };

  const onDelete = (r: Card) => {
    confirmDanger(
      '删除卡密',
      `确认删除卡密「${r.code}」？其账号、绑定设备、会话与充值记录将被一并删除，不可恢复。`,
      async () => {
        await deleteCard(r.code);
        message.success('已删除');
        actionRef.current?.reload();
      }
    );
  };

  const request = async (p: Record<string, unknown>) => {
    const params: CardListParams = {
      q: (p.q as string) || undefined,
      kind: (p.kind as string) || undefined,
      enabled:
        p.enabled === undefined || p.enabled === '' || p.enabled === null
          ? undefined
          : Number(p.enabled),
      channel_id: (p.channel_id as number) || undefined,
      current: Number(p.current ?? 1),
      pageSize: Number(p.pageSize ?? 20),
    };
    lastParams.current = params;
    const { items, total } = await listCards(params);
    return { data: items, total, success: true };
  };

  const onExport = async () => {
    try {
      const p = lastParams.current;
      await exportCards({
        q: p.q,
        kind: p.kind,
        enabled: p.enabled,
        channel_id: p.channel_id,
      });
      message.success('已导出 CSV');
    } catch (e) {
      message.error((e as Error)?.message || '导出失败');
    }
  };

  const onCreate = async () => {
    const v = await createForm.validateFields();
    setCreating(true);
    try {
      const cards = await createCards({
        code: v.code || undefined,
        kind: v.kind,
        hours: v.hours,
        max_devices: v.max_devices,
        note: v.note,
        count: v.count,
        channel_id: isSuper ? v.channel_id : undefined,
      });
      message.success(`已生成 ${cards.length} 张卡密`);
      setCreateOpen(false);
      createForm.resetFields();
      if (refreshUser) refreshUser().catch(() => undefined);
      actionRef.current?.reload();
    } catch (e) {
      message.error((e as Error)?.message || '发卡失败');
    } finally {
      setCreating(false);
    }
  };

  const columns: ProColumns<Card>[] = [
    {
      title: '搜索',
      dataIndex: 'q',
      hideInTable: true,
      valueType: 'text',
      fieldProps: { placeholder: '卡密 / 备注 / 渠道' },
    },
    {
      title: '卡密',
      dataIndex: 'code',
      search: false,
      ellipsis: true,
      width: 230,
      render: (_, r) => (
        <Space size={2}>
          <Typography.Text copyable={false} style={{ fontFamily: 'monospace' }}>{r.code}</Typography.Text>
          <CopyButton text={r.code} />
        </Space>
      ),
    },
    {
      title: '类型',
      dataIndex: 'kind',
      width: 100,
      valueType: 'select',
      valueEnum: {
        login: { text: '登录卡', status: 'Processing' },
        topup: { text: '充值卡', status: 'Warning' },
      },
      render: (_, r) =>
        r.kind === 'login' ? <Tag color="blue">登录卡</Tag> : <Tag color="orange">充值卡</Tag>,
    },
    {
      title: '状态',
      dataIndex: 'enabled',
      width: 90,
      valueType: 'select',
      valueEnum: {
        1: { text: '启用', status: 'Success' },
        0: { text: '停用', status: 'Error' },
      },
      render: (_, r) =>
        r.enabled === 1 ? <Tag color="green">启用</Tag> : <Tag color="red">停用</Tag>,
    },
    ...(isSuper
      ? [
          { title: '渠道', dataIndex: 'channel_name' as const, search: false, width: 140, render: (_: unknown, r: Card) => r.channel_name || '-' },
          {
            title: '渠道筛选',
            dataIndex: 'channel_id' as const,
            hideInTable: true,
            valueType: 'select' as const,
            fieldProps: { options: channelOptions, allowClear: true, placeholder: '全部渠道' },
          },
        ]
      : []),
    { title: '时长(h)', dataIndex: 'hours', search: false, width: 90 },
    { title: '最大设备', dataIndex: 'max_devices', search: false, width: 90 },
    { title: '设备数', dataIndex: 'device_count', search: false, width: 80 },
    {
      title: '账号到期',
      dataIndex: 'account_expires_at',
      search: false,
      width: 170,
      render: (_, r) => (r.account_expires_at ? formatTime(r.account_expires_at) : '-'),
    },
    { title: '备注', dataIndex: 'note', search: false, ellipsis: true },
    {
      title: '创建时间',
      dataIndex: 'created_at',
      search: false,
      width: 170,
      render: (_, r) => formatTime(r.created_at),
    },
    {
      title: '操作',
      valueType: 'option',
      width: 140,
      render: (_, r) => [
        r.enabled === 1 ? (
          <a key="stop" onClick={() => onToggle(r, false)}>
            <StopOutlined /> 停用
          </a>
        ) : (
          <a key="enable" onClick={() => onToggle(r, true)}>
            <PlayCircleOutlined /> 启用
          </a>
        ),
        <a key="del" style={{ color: '#ff4d4f' }} onClick={() => onDelete(r)}>
          删除
        </a>,
      ],
    },
  ];

  return (
    <>
      {!isSuper && user && (
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 16 }}
          message={`发卡配额：已用 ${user.quota_used} / ${user.card_quota}（登录卡占配额）`}
        />
      )}
      <ProTable<Card>
        headerTitle={
          <Space>
            <span>卡密管理</span>
            {isSuper && <Typography.Text type="secondary">超管可查看所有渠道卡密</Typography.Text>}
          </Space>
        }
        actionRef={actionRef}
        rowKey="code"
        columns={columns}
        request={request}
        search={{ labelWidth: 'auto' }}
        pagination={{ pageSize: 20, showSizeChanger: true, showTotal: (t) => `共 ${t} 条` }}
        scroll={{ x: 1200 }}
        toolBarRender={() => [
          <Button key="export" icon={<DownloadOutlined />} onClick={onExport}>
            导出CSV
          </Button>,
          <Button
            key="create"
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => setCreateOpen(true)}
          >
            发卡
          </Button>,
        ]}
      />

      <Modal
        title="发卡"
        open={createOpen}
        onOk={onCreate}
        confirmLoading={creating}
        onCancel={() => {
          setCreateOpen(false);
          createForm.resetFields();
        }}
        width={480}
      >
        <Form form={createForm} layout="vertical" initialValues={{ kind: 'login', hours: 720, max_devices: 1, count: 1 }}>
          <Form.Item name="kind" label="卡类型" rules={[{ required: true }]}>
            <Radio.Group>
              <Radio.Button value="login">登录卡</Radio.Button>
              <Radio.Button value="topup">充值卡</Radio.Button>
            </Radio.Group>
          </Form.Item>
          <Form.Item
            name="code"
            label="指定卡密（可选）"
            extra="留空则自动生成；指定时每次只能生成 1 张"
          >
            <Input placeholder="留空自动生成" allowClear />
          </Form.Item>
          <Form.Item name="hours" label="时长（小时）" rules={[{ required: true }]}>
            <InputNumber min={1} max={24 * 3650} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="max_devices" label="最大设备数" rules={[{ required: true }]}>
            <InputNumber min={0} max={50} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="count" label="生成数量" rules={[{ required: true }]}>
            <InputNumber min={1} max={200} style={{ width: '100%' }} />
          </Form.Item>
          {isSuper && (
            <Form.Item name="channel_id" label="归属渠道（可选）">
              <Select
                allowClear
                showSearch
                placeholder="不选则不属于任何渠道"
                options={channelOptions}
                optionFilterProp="label"
              />
            </Form.Item>
          )}
          <Form.Item name="note" label="备注">
            <Input placeholder="如：客户名称" allowClear />
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}
