// Home: the workspace's schemas, each with its type and what it holds.

import { Badge, Card, Group, SimpleGrid, Stack, Text, Title } from '@mantine/core'
import { useEffect, useState } from 'react'

import { model as fetchModel, schemas as fetchSchemas } from '../api'
import type { Schema, SchemaInfo } from '../model'

const TARGET = { postgres: 'PostgreSQL', mysql: 'MySQL', iceberg: 'Iceberg' } as const

export function Home({ open, version }: { open: (name: string) => void; version: number }) {
  const [list, setList] = useState<{ info: SchemaInfo; model?: Schema }[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    fetchSchemas()
      .then(async (infos) => {
        const models = await Promise.all(infos.map((i) => fetchModel(i.name).catch(() => undefined)))
        setList(infos.map((info, n) => ({ info, model: models[n] })))
      })
      .catch((e) => setError(String(e.message ?? e)))
  }, [version])
  return (
    <Stack p="xl" gap="lg" maw={1200}>
      <div>
        <Title order={2}>Schemas</Title>
        <Text c="dimmed" size="sm">
          Open one to see it from every side, or ask your agent to make a new one.
        </Text>
      </div>
      {error && <Text c="red">{error}</Text>}
      {list && list.length === 0 && (
        <Text c="dimmed">No schemas yet. Import one: schema-forge import &lt;dump or folder&gt; --schema &lt;name&gt;</Text>
      )}
      <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }}>
        {list?.map(({ info, model }) => (
          <Card key={info.name} className="sf-home-card" onClick={() => open(info.name)} padding="lg" radius="md" withBorder>
            <Group justify="space-between" mb="xs">
              <Text fw={700} size="lg" ff="heading">
                {info.name}
              </Text>
              <Badge variant="light">{TARGET[info.target]}</Badge>
            </Group>
            {model && (
              <Group gap="lg">
                <Stat n={model.tables?.length ?? 0} label="tables" />
                <Stat n={model.views?.length ?? 0} label="views" />
                <Stat n={model.relationships?.length ?? 0} label="relationships" />
                <Stat n={model.namespaces?.length ?? 0} label="namespaces" />
              </Group>
            )}
          </Card>
        ))}
      </SimpleGrid>
    </Stack>
  )
}

function Stat({ n, label }: { n: number; label: string }) {
  return (
    <div>
      <Text fw={700}>{n.toLocaleString()}</Text>
      <Text size="xs" c="dimmed">
        {label}
      </Text>
    </div>
  )
}
