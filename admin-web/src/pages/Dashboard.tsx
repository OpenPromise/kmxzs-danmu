import { useEffect, useState } from 'react';
import { App, Card, Col, Progress, Row, Table, Tag } from 'antd';
import { getOverview } from '../api';
import StatCard from '../components/StatCard';
import { useAuth } from '../context/AuthContext';
import type { AdminOverview, Channel, ResellerOverview } from '../types';

export default function Dashboard() {
  const { user } = useAuth();
  const { message } = App.useApp();
  const [overview, setOverview] = useState<AdminOverview | ResellerOverview | null>(null);

  useEffect(() => {
    getOverview()
      .then(setOverview)
      .catch((e) => message.error((e as Error)?.message || '加载数据失败'));
  }, []);

  const isSuper = user?.role === 'superadmin';

  if (isSuper) {
    const o = overview as AdminOverview | null;
    return (
      <div>
        <Row gutter={[16, 16]}>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="卡密总数" value={o?.cardsTotal ?? 0} />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="启用登录卡" value={o?.cardsLoginEnabled ?? 0} color="#1677ff" />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="启用充值卡" value={o?.cardsTopupEnabled ?? 0} color="#faad14" />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="账号数" value={o?.accounts ?? 0} />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="设备数" value={o?.devices ?? 0} />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="会话数" value={o?.sessions ?? 0} />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="已用充值卡" value={o?.topupUsed ?? 0} />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="用户数" value={o?.users ?? 0} />
          </Col>
          <Col xs={12} sm={8} md={6} xl={4}>
            <StatCard title="启用代理" value={o?.resellers ?? 0} color="#52c41a" />
          </Col>
        </Row>
        <Card title="渠道分布" style={{ marginTop: 16 }}>
          <Table<Channel>
            rowKey="id"
            dataSource={o?.channels ?? []}
            pagination={false}
            size="small"
            columns={[
              { title: '编码', dataIndex: 'code', width: 160 },
              { title: '名称', dataIndex: 'name' },
              { title: '卡密数', dataIndex: 'card_count', width: 100 },
              { title: '代理数', dataIndex: 'agent_count', width: 100 },
              {
                title: '状态',
                dataIndex: 'status',
                width: 100,
                render: (v: number) =>
                  v === 1 ? <Tag color="green">启用</Tag> : <Tag color="red">停用</Tag>,
              },
              { title: '创建时间', dataIndex: 'created_at', width: 180 },
            ]}
          />
        </Card>
      </div>
    );
  }

  const o = overview as ResellerOverview | null;
  const quota = o?.quota ?? 0;
  const used = o?.quota_used ?? 0;
  const pct = quota > 0 ? Math.min(100, Math.round((used / quota) * 100)) : 0;
  return (
    <div>
      <Row gutter={[16, 16]}>
        <Col xs={12} sm={8} md={6} xl={4}>
          <StatCard title="卡密总数" value={o?.cardsTotal ?? 0} />
        </Col>
        <Col xs={12} sm={8} md={6} xl={4}>
          <StatCard title="启用登录卡" value={o?.cardsLoginEnabled ?? 0} color="#1677ff" />
        </Col>
        <Col xs={12} sm={8} md={6} xl={4}>
          <StatCard title="启用充值卡" value={o?.cardsTopupEnabled ?? 0} color="#faad14" />
        </Col>
        <Col xs={12} sm={8} md={6} xl={4}>
          <StatCard title="账号数" value={o?.accounts ?? 0} />
        </Col>
        <Col xs={12} sm={8} md={6} xl={4}>
          <StatCard title="设备数" value={o?.devices ?? 0} />
        </Col>
        <Col xs={12} sm={8} md={6} xl={4}>
          <StatCard title="发卡配额" value={quota} />
        </Col>
      </Row>
      <Card title="发卡配额使用" style={{ marginTop: 16 }}>
        <Progress
          percent={pct}
          status={pct >= 100 ? 'exception' : 'active'}
          format={() => `${used} / ${quota}`}
        />
        <div style={{ color: '#8c8c8c', marginTop: 8 }}>
          登录卡按已创建且启用的数量占配额，充值卡不占配额。
        </div>
      </Card>
    </div>
  );
}
