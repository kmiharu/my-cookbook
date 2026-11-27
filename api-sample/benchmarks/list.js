import http from 'k6/http';
import { check } from 'k6';

const base = __ENV.BENCH_BASE;
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(base || '')) {
  throw new Error('BENCH_BASE must point to the loopback benchmark API');
}

export const options = {
  summaryTrendStats: ['avg', 'med', 'p(50)', 'p(95)', 'p(99)', 'max'],
  discardResponseBodies: false,
};

export default function () {
  const response = http.get(`${base}/products?category=bench-0&limit=20`, {
    headers: { 'X-Request-Id': 'cookbook-benchmark' },
    timeout: '5s',
    redirects: 0,
  });
  check(response, {
    'page with 20 products': (r) => {
      if (r.status !== 200) return false;
      try {
        const rows = r.json('items');
        return Array.isArray(rows) && rows.length === 20;
      } catch (_) {
        return false;
      }
    },
  });
}

export function handleSummary(data) {
  return { [__ENV.BENCH_K6_OUTPUT]: JSON.stringify(data) };
}
