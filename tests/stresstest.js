import http from 'k6/http';
import { sleep, check } from 'k6';

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
const targetUrl = __ENV.AWS_URL || dotEnv.AWS_URL;

if (!targetUrl) {
  throw new Error('Defini AWS_URL en tests/.env o pasalo como variable de entorno para k6.');
}

export const options = {
  vus: 50,
  duration: '30s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<800'],
  },
};

export default function () {
  const res = http.get(targetUrl, {
    tags: {
      scenario: 'odoo-login-page',
    },
  });

  check(res, {
    'status es 200': (r) => r.status === 200,
    'tiempo de respuesta < 800ms': (r) => r.timings.duration < 800,
  });

  sleep(1);
}