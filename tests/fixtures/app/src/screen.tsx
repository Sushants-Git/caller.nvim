import { Panel } from 'components/Panel';
import { Badge } from '@widgets/Badge';
import { Panel as Aliased } from 'components/Panel';

export const Screen = () => (
  <div>
    <Panel title="a" />
    <Panel title="b">child</Panel>
    <Badge />
    <Aliased title="c" />
  </div>
);

export const notRendered = Panel;
