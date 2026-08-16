import { Card, Statistic } from 'antd';

interface Props {
  title: string;
  value: number | string;
  suffix?: string;
  color?: string;
  precision?: number;
}

export default function StatCard({ title, value, suffix, color, precision }: Props) {
  return (
    <Card size="small" styles={{ body: { padding: 16 } }}>
      <Statistic
        title={title}
        value={typeof value === 'number' ? value : Number(value) || 0}
        precision={precision}
        suffix={suffix}
        valueStyle={color ? { color } : undefined}
      />
    </Card>
  );
}
