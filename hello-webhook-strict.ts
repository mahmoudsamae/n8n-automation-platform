import { workflow, trigger, node, ifElse, expr } from '@n8n/workflow-sdk';

const webhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.2,
  config: {
    name: 'Webhook',
    parameters: {
      httpMethod: 'POST',
      path: 'hello-strict',
      authentication: 'none',
      responseMode: 'responseNode'
    }
  }
});

const nameValid = ifElse({
  version: 2.2,
  config: {
    name: 'Name valid?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [
          {
            leftValue: expr("{{ typeof $json.body?.name === 'string' && $json.body.name.trim().length > 0 }}"),
            operator: { type: 'boolean', operation: 'true', singleValue: true }
          }
        ],
        combinator: 'and'
      }
    }
  }
});

const respondOk = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 200',
    parameters: {
      respondWith: 'json',
      responseBody: expr("{{ JSON.stringify({ greeting: 'Hallo ' + $json.body.name.trim(), received_at: new Date().toISOString() }) }}"),
      options: { responseCode: 200 }
    }
  }
});

const respondBad = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond 400',
    parameters: {
      respondWith: 'json',
      responseBody: JSON.stringify({ error: 'name is required' }),
      options: { responseCode: 400 }
    }
  }
});

export default workflow('hello-webhook-strict', 'Hello Webhook - Strict')
  .add(webhook)
  .to(nameValid.onTrue(respondOk).onFalse(respondBad));
