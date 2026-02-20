# Merchant Center: Forms, UI Kit & Routing

Forms with Formik, UI Kit design system components, routing patterns, internationalization, and development checklist for Merchant Center custom applications.

## Table of Contents
- [Forms with Formik](#forms-with-formik)
  - [Basic Form Pattern](#basic-form-pattern)
  - [Data Conversion Functions](#data-conversion-functions)
  - [FormModalPage for Create/Edit Flows](#formmodalpage-for-createedit-flows)
  - [Incorrect Form Patterns](#incorrect-form-patterns)
- [UI Kit Components](#ui-kit-components)
  - [Layout with Spacings](#layout-with-spacings)
  - [Typography](#typography)
  - [DataTable for Lists](#datatable-for-lists)
  - [Buttons](#buttons)
  - [Field Components](#field-components)
  - [Notifications](#notifications)
  - [Page Content Layouts](#page-content-layouts)
  - [Page-Level Layout Components](#page-level-layout-components)
- [Routing Patterns](#routing-patterns)
  - [Tabbed Detail Pages](#tabbed-detail-pages)
  - [Link Navigation](#link-navigation)
- [Application Context & Internationalization](#application-context--internationalization)
- [Checklist: UI Development](#checklist-ui-development)
- [Reference](#reference)

## Forms with Formik

The MC SDK is designed around Formik for form state management. UI Kit field components expect Formik-compatible props.

### Basic Form Pattern

```tsx
import { useFormik } from 'formik';
import TextField from '@commercetools-uikit/text-field';
import LocalizedTextField from '@commercetools-uikit/localized-text-field';
import LocalizedTextInput from '@commercetools-uikit/localized-text-input';
import PrimaryButton from '@commercetools-uikit/primary-button';
import Spacings from '@commercetools-uikit/spacings';

type TFormValues = {
  key: string;
  name: Record<string, string>;
};

type TChannelForm = {
  initialValues: TFormValues;
  onSubmit: (values: TFormValues) => Promise<void>;
  dataLocale: string;
};

const ChannelForm = ({ initialValues, onSubmit, dataLocale }: TChannelForm) => {
  const formik = useFormik<TFormValues>({
    initialValues,
    enableReinitialize: true,
    validate: (values) => {
      const errors: Record<string, { missing?: boolean }> = {};
      if (!values.key || values.key.trim() === '') {
        errors.key = { missing: true };
      }
      if (LocalizedTextInput.isEmpty(values.name)) {
        errors.name = { missing: true };
      }
      return errors;
    },
    onSubmit: async (values) => {
      await onSubmit(values);
    },
  });

  return (
    <form onSubmit={formik.handleSubmit}>
      <Spacings.Stack scale="l">
        <TextField
          name="key"
          title="Key"
          isRequired
          value={formik.values.key}
          errors={
            TextField.toFieldErrors<TFormValues>(formik.errors).key
          }
          touched={formik.touched.key}
          onChange={formik.handleChange}
          onBlur={formik.handleBlur}
        />
        <LocalizedTextField
          name="name"
          title="Name"
          isRequired
          selectedLanguage={dataLocale}
          value={formik.values.name}
          errors={
            LocalizedTextField.toFieldErrors<TFormValues>(formik.errors).name
          }
          touched={!!formik.touched.name}
          onChange={formik.handleChange}
          onBlur={formik.handleBlur}
        />
        <PrimaryButton
          type="submit"
          label="Save"
          isDisabled={formik.isSubmitting || !formik.dirty}
        />
      </Spacings.Stack>
    </form>
  );
};
```

### Data Conversion Functions

Always convert between API data shapes and form values. This pattern is used in Aries Labs Emailer for template data.

```tsx
// Convert API response to form-friendly values
const docToFormValues = (channel: TChannel): TFormValues => ({
  key: channel.key ?? '',
  name: channel.nameAllLocales?.reduce(
    (acc, { locale, value }) => ({ ...acc, [locale]: value }),
    {} as Record<string, string>
  ) ?? {},
});

// Convert form values back to API update actions
const formValuesToDoc = (values: TFormValues): TUpdateAction[] => {
  const actions: TUpdateAction[] = [];
  actions.push({
    changeName: {
      name: Object.entries(values.name)
        .filter(([, value]) => value.trim() !== '')
        .reduce((acc, [locale, value]) => ({ ...acc, [locale]: value }), {}),
    },
  });
  if (values.key) {
    actions.push({ changeKey: { key: values.key } });
  }
  return actions;
};
```

### FormModalPage for Create/Edit Flows

```tsx
import {
  FormModalPage,
} from '@commercetools-frontend/application-components';
import { useFormik } from 'formik';

const CreateResource = ({ onClose }: { onClose: () => void }) => {
  const formik = useFormik({
    initialValues: { key: '', name: {} },
    onSubmit: async (values) => {
      await createResource(values);
      onClose();
    },
  });

  return (
    <FormModalPage
      title="Create Resource"
      isOpen
      onClose={onClose}
      isPrimaryButtonDisabled={formik.isSubmitting || !formik.dirty}
      onPrimaryButtonClick={() => formik.handleSubmit()}
      onSecondaryButtonClick={onClose}
    >
      <Spacings.Stack scale="l">
        <TextField
          name="key"
          title="Key"
          value={formik.values.key}
          onChange={formik.handleChange}
        />
      </Spacings.Stack>
    </FormModalPage>
  );
};
```

### Incorrect Form Patterns

```tsx
// WRONG: Using raw React state instead of Formik
const [key, setKey] = useState('');
// Missing: validation, touched tracking, error display, submission state
// UI Kit fields expect Formik-compatible props (errors, touched)

// WRONG: Not using enableReinitialize
const formik = useFormik({
  initialValues: docToFormValues(channel),
  // Missing enableReinitialize: true
  // Form will not update when data is refetched
});

// WRONG: Displaying errors before the field is touched
<TextField
  errors={formik.errors.key}
  touched={true}  // Always true -- shows errors immediately on page load
/>
```

## UI Kit Components

The ui-kit design system provides components that match the built-in Merchant Center UX. Always prefer ui-kit components over custom HTML or third-party libraries.

### Layout with Spacings

```tsx
import Spacings from '@commercetools-uikit/spacings';

// Vertical stack
<Spacings.Stack scale="l">  {/* xs | s | m | l | xl */}
  <Header />
  <Content />
  <Footer />
</Spacings.Stack>

// Horizontal row
<Spacings.Inline scale="m" alignItems="center">
  <SearchInput />
  <PrimaryButton label="Search" />
</Spacings.Inline>
```

### Typography

Use `Text` from `@commercetools-uikit/text` with variants: `Text.Headline` (h1-h3), `Text.Subheadline` (h4-h5), `Text.Body`, `Text.Detail`, `Text.Caption`. Pass `as` prop for semantic HTML element.

### DataTable for Lists

Used extensively in Aries Labs Custom Objects Editor for displaying object lists.

```tsx
import DataTable from '@commercetools-uikit/data-table';

type TChannel = {
  id: string;
  key: string;
  name: string;
  roles: string[];
};

const columns = [
  { key: 'key', label: 'Key', isSortable: true },
  { key: 'name', label: 'Name', isSortable: true },
  { key: 'roles', label: 'Roles' },
];

const ChannelList = ({ channels }: { channels: TChannel[] }) => (
  <DataTable<TChannel>
    columns={columns}
    rows={channels}
    itemRenderer={(item, column) => {
      switch (column.key) {
        case 'key':
          return item.key;
        case 'name':
          return item.name;
        case 'roles':
          return item.roles.join(', ');
        default:
          return null;
      }
    }}
    onRowClick={(row) => {
      // Navigate to detail page
    }}
  />
);
```

### Buttons

Use `PrimaryButton` for main actions, `SecondaryButton` for secondary actions, `FlatButton` for tertiary/navigation, and `IconButton` with icons from `@commercetools-uikit/icons`. All support `isDisabled` prop for permission-based disabling.

### Field Components

UI Kit provides paired Field/Input components. Fields include labels, error messages, and accessibility. Key fields: `TextField`, `LocalizedTextField`, `MultilineTextField`, `NumberField`, `MoneyField`, `SelectField`, `AsyncSelectField`, `DateField`, `DateTimeField`. Standalone inputs: `ToggleInput`, `CheckboxInput`, `RadioInput`. See [UI Kit explorer](https://uikit.commercetools.com) for the full catalog.

### Notifications

Two notification domains exist:

| Domain | Behavior | Use For |
|--------|----------|---------|
| `DOMAINS.SIDE` | Auto-dismisses after 5 seconds | Success feedback, brief info |
| `DOMAINS.PAGE` | Requires manual close | Errors, important warnings |

**Side notification kinds:** `success`, `error`, `warning`, `info`
**Page notification kinds:** `success`, `error`, `warning`, `info`, `unexpected-error`, `api-error`

```tsx
import { useShowNotification, useShowApiErrorNotification } from '@commercetools-frontend/actions-global';
import { DOMAINS, NOTIFICATION_KINDS_SIDE } from '@commercetools-frontend/constants';

const MyComponent = () => {
  const showNotification = useShowNotification();
  const showApiErrorNotification = useShowApiErrorNotification();

  const handleSave = async () => {
    try {
      await updateResource(data);
      showNotification({
        kind: NOTIFICATION_KINDS_SIDE.success,
        domain: DOMAINS.SIDE,
        text: 'Resource updated successfully',
      });
    } catch (error) {
      showApiErrorNotification({ errors: error.graphQLErrors });
    }
  };
};
```

Always show success notifications after saves and error notifications on failures. Use `useShowApiErrorNotification` for GraphQL errors -- it automatically formats the error response for display.

### Page Content Layouts

All from `@commercetools-frontend/application-components`:

| Component | Use For |
|-----------|---------|
| `PageContentFull` | List pages with full-width tables |
| `PageContentWide` | Large forms, supports `columns="1/1"` or `columns="2/1"` |
| `PageContentNarrow` | Simple forms, collapsible panels |

```tsx
import {
  PageContentFull,
  PageContentWide,
  PageContentNarrow,
} from '@commercetools-frontend/application-components';

// Full-width list page
<PageContentFull>
  <DataTable columns={columns} rows={data} />
</PageContentFull>

// Two-column detail page (2:1 ratio)
<PageContentWide columns="2/1">
  <Spacings.Stack scale="l">
    <ChannelForm />
  </Spacings.Stack>
  <Spacings.Stack scale="l">
    <MetaInfo />
  </Spacings.Stack>
</PageContentWide>
```

### Page-Level Layout Components

| Component | Use For |
|-----------|---------|
| `InfoDetailPage` | Read-only detail pages (back navigation + title) |
| `FormDetailPage` | Editable detail pages (back navigation + save/cancel buttons) |
| `TabularDetailPage` | Detail pages with tabs |
| `InfoModalPage` | Read-only modal overlays |
| `FormModalPage` | Create/edit modal overlays (save/cancel buttons) |
| `TabularModalPage` | Modal overlays with tabs |
| `CustomFormModalPage` | Modal with fully custom footer |
| `CustomFormDetailPage` | Detail page with fully custom footer |
| `InfoMainPage` | Top-level read-only page |
| `FormMainPage` | Top-level form page |
| `TabularMainPage` | Top-level page with tabs |
| `Drawer` | Side drawer panel |
| `PageUnauthorized` | Standard 403 page |
| `PageNotFound` | Standard 404 page |

## Routing Patterns

### Tabbed Detail Pages

A common pattern in Aries Labs Shop Assist for viewing cart details with multiple tabs:

```tsx
import { Switch, Route, useRouteMatch, useHistory } from 'react-router-dom';
import { TabHeader, TabularDetailPage } from '@commercetools-frontend/application-components';

const ResourceDetail = () => {
  const match = useRouteMatch();
  const history = useHistory();

  return (
    <TabularDetailPage
      title="Resource Detail"
      onPreviousPathClick={() => history.goBack()}
      tabControls={
        <>
          <TabHeader
            to={`${match.url}/general`}
            label="General"
          />
          <TabHeader
            to={`${match.url}/settings`}
            label="Settings"
          />
        </>
      }
    >
      <Switch>
        <Route path={`${match.path}/settings`}>
          <SettingsTab />
        </Route>
        <Route>
          <GeneralTab />
        </Route>
      </Switch>
    </TabularDetailPage>
  );
};
```

### Link Navigation

Use `Link` from `@commercetools-uikit/link` with `useRouteMatch` for navigation: `<Link to={`${match.url}/${resource.id}`}>`. Always build link targets relative to `match.url`, never hardcoded paths.

## Application Context & Internationalization

Access project, user, and locale info via `useApplicationContext` from `@commercetools-frontend/application-shell-connectors`. The selector pattern `(context) => ({ project: context.project, dataLocale: context.dataLocale })` avoids unnecessary re-renders.

All user-facing strings must use `react-intl`. Define messages with `{ id, defaultMessage }` objects and render with `<FormattedMessage>` or `intl.formatMessage()`. The MC SDK provides message loading infrastructure through the `applicationMessages` prop on `ApplicationShell`.

## Checklist: UI Development

- [ ] Data fetching uses `useMcQuery`/`useMcMutation` with `GRAPHQL_TARGETS` (not raw Apollo)
- [ ] GraphQL queries are in `.ctp.graphql` files
- [ ] Data logic is extracted into connector hooks (not inline in components)
- [ ] External API calls use Forward-To proxy (not direct browser requests)
- [ ] Forms use Formik with `enableReinitialize: true`
- [ ] Form validation returns `{ missing: true }` error objects for required fields
- [ ] Error display is gated on `touched` state (no premature validation)
- [ ] `docToFormValues` and `formValuesToDoc` conversion functions exist
- [ ] UI components are from `@commercetools-uikit/*` (not raw HTML or third-party)
- [ ] Layout uses `Spacings.Stack` and `Spacings.Inline` for consistent spacing
- [ ] Page layouts use `PageContentFull`/`PageContentWide`/`PageContentNarrow`
- [ ] All user-facing strings use react-intl (not hardcoded strings)
- [ ] Success notifications use `DOMAINS.SIDE` (auto-dismiss)
- [ ] Error notifications use `useShowApiErrorNotification` for GraphQL errors
- [ ] Routes use `useRouteMatch` or `useRoutesCreator` for path construction
- [ ] Permission checks disable or hide write actions for view-only users

## Reference

- [Data Fetching guide](https://docs.commercetools.com/merchant-center-customizations/development/data-fetching)
- [Forms guide](https://docs.commercetools.com/merchant-center-customizations/development/forms)
- [Routing guide](https://docs.commercetools.com/merchant-center-customizations/development/routing)
- [UI Components guide](https://docs.commercetools.com/merchant-center-customizations/development/ui-components)
- [UI Kit interactive explorer](https://uikit.commercetools.com)
- [Application Components](https://docs.commercetools.com/merchant-center-customizations/tooling-and-configuration/commercetools-frontend-application-components)
