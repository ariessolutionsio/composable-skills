# Merchant Center: Data Fetching Patterns

GraphQL with useMcQuery, mutations, REST data fetching, Forward-To proxy for external APIs, and connector hook patterns for Merchant Center custom applications.

## Data Fetching

### GraphQL with useMcQuery (Recommended)

The MC SDK wraps Apollo Client with authentication and proxy routing built in. Always use the MC-specific hooks rather than raw Apollo hooks.

```tsx
// src/hooks/use-channels-connector/fetch-channels.ctp.graphql
query FetchChannels($limit: Int!, $offset: Int!) {
  channels(limit: $limit, offset: $offset) {
    results {
      id
      version
      key
      nameAllLocales {
        locale
        value
      }
      roles
    }
    total
    count
  }
}
```

```tsx
// src/hooks/use-channels-connector/use-channels-connector.ts
import { useMcQuery } from '@commercetools-frontend/application-shell';
import { GRAPHQL_TARGETS } from '@commercetools-frontend/constants';
import FetchChannelsQuery from './fetch-channels.ctp.graphql';

type TUseChannelsConnector = {
  limit: number;
  offset: number;
};

export const useChannelsConnector = ({ limit, offset }: TUseChannelsConnector) => {
  const { data, error, loading } = useMcQuery(FetchChannelsQuery, {
    variables: { limit, offset },
    context: {
      target: GRAPHQL_TARGETS.COMMERCETOOLS_PLATFORM,
    },
  });

  return {
    channels: data?.channels?.results ?? [],
    total: data?.channels?.total ?? 0,
    error,
    loading,
  };
};
```

**Incorrect -- using raw Apollo useQuery:**

```tsx
// WRONG: Missing MC authentication context
import { useQuery } from '@apollo/client';

const { data } = useQuery(FetchChannelsQuery);
// This will fail -- no target context, no authentication headers

// CORRECT: Use useMcQuery with GRAPHQL_TARGETS
import { useMcQuery } from '@commercetools-frontend/application-shell';
import { GRAPHQL_TARGETS } from '@commercetools-frontend/constants';

const { data } = useMcQuery(FetchChannelsQuery, {
  context: {
    target: GRAPHQL_TARGETS.COMMERCETOOLS_PLATFORM,
  },
});
```

### Mutations with useMcMutation

```tsx
import { useMcMutation } from '@commercetools-frontend/application-shell';
import { GRAPHQL_TARGETS } from '@commercetools-frontend/constants';
import UpdateChannelMutation from './update-channel.ctp.graphql';

const useUpdateChannel = () => {
  const [updateChannel, { loading }] = useMcMutation(UpdateChannelMutation);

  const execute = async (id: string, version: number, actions: unknown[]) => {
    const result = await updateChannel({
      variables: { id, version, actions },
      context: {
        target: GRAPHQL_TARGETS.COMMERCETOOLS_PLATFORM,
      },
    });
    return result.data?.updateChannel;
  };

  return { execute, loading };
};
```

### Available GRAPHQL_TARGETS

| Target | Purpose |
|--------|---------|
| `GRAPHQL_TARGETS.COMMERCETOOLS_PLATFORM` | commercetools platform API (products, orders, customers, etc.) |
| `GRAPHQL_TARGETS.MERCHANT_CENTER_BACKEND` | Merchant Center internal API |
| `GRAPHQL_TARGETS.SETTINGS_SERVICE` | MC settings service |

Most custom applications use `COMMERCETOOLS_PLATFORM` exclusively.

### REST Data Fetching with SDK

For REST endpoints when GraphQL is not suitable:

```tsx
import { useAsyncDispatch, actions } from '@commercetools-frontend/sdk';
import { MC_API_PROXY_TARGETS } from '@commercetools-frontend/constants';

const MyComponent = () => {
  const dispatch = useAsyncDispatch();

  const fetchChannels = async () => {
    const result = await dispatch(
      actions.get({
        mcApiProxyTarget: MC_API_PROXY_TARGETS.COMMERCETOOLS_PLATFORM,
        service: 'channels',
      })
    );
    return result;
  };
};
```

**Available MC_API_PROXY_TARGETS:**

| Target | Routes To |
|--------|-----------|
| `MC_API_PROXY_TARGETS.COMMERCETOOLS_PLATFORM` | `/proxy/ctp/*` -- Composable Commerce HTTP API |
| `MC_API_PROXY_TARGETS.IMPORT` | `/proxy/import/*` -- Import API |

### Custom HTTP Clients (Fetch, Axios, SWR)

For non-Apollo clients, use `executeHttpClientRequest` with `buildApiUrl` for automatic token handling:

```tsx
import {
  buildApiUrl,
  executeHttpClientRequest,
} from '@commercetools-frontend/application-shell';
import { createHttpUserAgent } from '@commercetools/http-user-agent';

const userAgent = createHttpUserAgent({
  name: 'my-custom-app',
  version: '1.0.0',
  contactEmail: 'support@example.com',
});

const fetcher = async (url: string) => {
  const data = await executeHttpClientRequest(
    async (options) => {
      const res = await fetch(buildApiUrl(url), options);
      return {
        data: await res.json(),
        statusCode: res.status,
        getHeader: (key: string) => res.headers.get(key),
      };
    },
    { userAgent }
  );
  return data;
};
```

### Forward-To Proxy for External APIs

To call your own API through the MC API Gateway (preserving authentication):

```tsx
// GraphQL approach -- use createApolloContextForProxyForwardTo
import { createApolloContextForProxyForwardTo } from '@commercetools-frontend/application-shell';

const { data } = useMcQuery(MyExternalQuery, {
  context: createApolloContextForProxyForwardTo({
    uri: 'https://my-api.example.com/graphql',
  }),
});

// REST approach -- use SDK forwardTo actions
import { useAsyncDispatch, actions } from '@commercetools-frontend/sdk';

const dispatch = useAsyncDispatch();
const result = await dispatch(
  actions.forwardTo.post({
    uri: 'https://my-api.example.com/api/data',
    payload: { key: 'value' },
  })
);

// With custom headers (prefix stripped before forwarding)
await dispatch(
  actions.forwardTo.get({
    uri: 'https://my-api.example.com/api',
    headers: { 'x-foo': 'bar' },  // Arrives as x-foo: bar
  })
);

// Include user permissions in JWT
await dispatch(
  actions.forwardTo.get({
    uri: 'https://my-api.example.com/api',
    includeUserPermissions: true,
  })
);
```

**Server-side JWT validation** (on your external API):

```typescript
// npm install @commercetools-backend/express
import {
  createSessionMiddleware,
  CLOUD_IDENTIFIERS,
} from '@commercetools-backend/express';

// Express middleware
app.use(
  createSessionMiddleware({
    audience: 'https://my-api.example.com',
    issuer: CLOUD_IDENTIFIERS.GCP_EU,
  })
);

app.use((req, res, next) => {
  // req.session = { userId, projectKey, userPermissions? }
});

// Serverless / Lambda
import { createSessionAuthVerifier, CLOUD_IDENTIFIERS } from '@commercetools-backend/express';

const verifier = createSessionAuthVerifier({
  audience: 'https://my-api.example.com',
  issuer: CLOUD_IDENTIFIERS.GCP_EU,
});

export async function handler(req, res) {
  try {
    await verifier(req, res);
  } catch {
    return res.status(401).json({ message: 'Unauthorized' });
  }
  // req.session available
}
```

The Forward-To proxy sends a short-lived JWT (60-second validity). Your API validates it via the `/.well-known/jwks.json` endpoint.

**Anti-Pattern -- calling external APIs directly from the browser:**
```tsx
// WRONG: Bypasses MC authentication, exposes API to CORS issues
const data = await fetch('https://my-api.example.com/data');

// CORRECT: Route through the Forward-To proxy
const data = await dispatch(
  actions.forwardTo.get({ uri: 'https://my-api.example.com/data' })
);
```

### Connector Hook Pattern

Extract data fetching logic into dedicated connector hooks for reusability. This pattern is used extensively in Aries Labs projects like Custom Objects Editor.

```tsx
// src/hooks/use-channel-details-connector/index.ts
import { useMcQuery, useMcMutation } from '@commercetools-frontend/application-shell';
import { GRAPHQL_TARGETS } from '@commercetools-frontend/constants';
import FetchChannelQuery from './fetch-channel.ctp.graphql';
import UpdateChannelMutation from './update-channel.ctp.graphql';

export const useChannelDetailsConnector = (channelId: string) => {
  const { data, error, loading, refetch } = useMcQuery(FetchChannelQuery, {
    variables: { id: channelId },
    context: { target: GRAPHQL_TARGETS.COMMERCETOOLS_PLATFORM },
  });

  const [updateChannel] = useMcMutation(UpdateChannelMutation);

  const handleUpdate = async (version: number, actions: unknown[]) => {
    await updateChannel({
      variables: { id: channelId, version, actions },
      context: { target: GRAPHQL_TARGETS.COMMERCETOOLS_PLATFORM },
    });
    await refetch();
  };

  return {
    channel: data?.channel,
    error,
    loading,
    updateChannel: handleUpdate,
  };
};
```
