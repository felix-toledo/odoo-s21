import http from 'k6/http';
import { sleep, check, group } from 'k6';

function parseDotEnv(contents) {
  return contents
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
    .reduce((envVars, line) => {
      const separatorIndex = line.indexOf('=');
      if (separatorIndex === -1) {
        return envVars;
      }
      const key = line.slice(0, separatorIndex).trim();
      const value = line.slice(separatorIndex + 1).trim();
      if (!key) {
        return envVars;
      }
      envVars[key] = value;
      return envVars;
    }, {});
}

const dotEnv = parseDotEnv(open('./.env'));
const baseUrl = __ENV.AWS_URL || dotEnv.AWS_URL;
const odooUser = __ENV.ODOO_USER || dotEnv.ODOO_USER || 'admin@example.com';
const odooPass = __ENV.ODOO_PASS || dotEnv.ODOO_PASS || 'admin';

if (!baseUrl) {
  throw new Error('Define AWS_URL en tests/.env o pasalo como variable de entorno para k6.');
}

// Limpiar baseUrl si tiene rutas incluidas
const targetUrl = baseUrl
  .split('/web')[0]
  .split('/api')[0];

console.log('Target URL:', targetUrl);
console.log('User:', odooUser);

export const options = {
  vus: 20,
  duration: '30s',
  thresholds: {
    http_req_failed: ['rate<0.1'],
    http_req_duration: ['p(95)<3000'],
  },
};

export function setup() {
  // Login una sola vez para obtener session
  // Odoo espera formdata, no JSON-RPC para /web/session/authenticate
  console.log('Intentando login en:', `${targetUrl}/web/session/authenticate`);
  
  const payload = {
    db: 'odoo',
    login: odooUser,
    password: odooPass,
  };
  
  const loginRes = http.post(`${targetUrl}/web/session/authenticate`, payload, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  });

  console.log('Login status:', loginRes.status);
  console.log('Login body:', loginRes.body ? loginRes.body.substring(0, 200) : 'empty');

  check(loginRes, {
    'login exitoso': (r) => r.status === 200,
  });

  const cookies = loginRes.cookies;
  const sessionId = cookies['session_id']?.[0]?.value;
  
  if (!sessionId) {
    console.warn('⚠️ No se obtuvo sessionId. Cookies:', Object.keys(loginRes.cookies));
    throw new Error('Login failed - no session cookie');
  } else {
    console.log('✓ SessionId obtenido:', sessionId.substring(0, 20) + '...');
  }
  
  return { sessionId };
}

export default function (data) {
  const { sessionId } = data;

  if (!sessionId) {
    console.warn('⚠️ No hay sessionId disponible, saltando requests');
    return;
  }

  group('Lectura de productos (stock)', () => {
    const res = http.post(`${targetUrl}/web/dataset/call_kw`, {
      jsonrpc: '2.0',
      method: 'call',
      params: {
        model: 'product.product',
        method: 'search_read',
        args: [],
        kwargs: {
          fields: ['id', 'name', 'qty_available', 'list_price'],
          limit: 50,
        },
      },
    }, {
      headers: {
        'Content-Type': 'application/json',
        'Cookie': `session_id=${sessionId}`,
      },
      tags: { scenario: 'fetch-products' },
    });

    check(res, {
      'status 200': (r) => r.status === 200,
      'tiene resultado': (r) => r.status === 200 && r.body && r.body.includes('result'),
    });
  });

  sleep(1);

  group('Lectura de turnos/reservas', () => {
    const res = http.post(`${targetUrl}/web/dataset/call_kw`, {
      jsonrpc: '2.0',
      method: 'call',
      params: {
        model: 'resource.booking',
        method: 'search_read',
        args: [],
        kwargs: {
          fields: ['id', 'name', 'date_start', 'date_end', 'state'],
          limit: 100,
        },
      },
    }, {
      headers: {
        'Content-Type': 'application/json',
        'Cookie': `session_id=${sessionId}`,
      },
      tags: { scenario: 'fetch-bookings' },
    });

    check(res, {
      'status 200': (r) => r.status === 200,
      'respuesta válida': (r) => r.status === 200 && r.body !== null && r.body !== '',
    });
  });

  sleep(1);

  group('Lectura de órdenes de venta', () => {
    const res = http.post(`${targetUrl}/web/dataset/call_kw`, {
      jsonrpc: '2.0',
      method: 'call',
      params: {
        model: 'sale.order',
        method: 'search_read',
        args: [],
        kwargs: {
          fields: ['id', 'name', 'amount_total', 'state', 'date_order'],
          limit: 50,
        },
      },
    }, {
      headers: {
        'Content-Type': 'application/json',
        'Cookie': `session_id=${sessionId}`,
      },
      tags: { scenario: 'fetch-sales-orders' },
    });

    check(res, {
      'status 200': (r) => r.status === 200,
      'respuesta válida': (r) => r.status === 200 && r.body !== null,
    });
  });

  sleep(1);
}