/**
 * k6 load test — service-1 autoscaling demonstration
 *
 * Usage:
 *   TOKEN=$(cat infra/jwt/token.jwt)
 *   GW_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
 *             -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
 *   k6 run -e TOKEN=$TOKEN -e GW_IP=$GW_IP scripts/load-test.js
 *
 * Expected result:
 *   20 VUs × 2 req/s = ~40 req/s → KEDA scales service-1 to 5 replicas
 *   After test ends, scale-down occurs within ~2-3 minutes (cooldownPeriod=60s)
 *
 * Watch scale-up in a separate terminal:
 *   kubectl get pods -n service-1 -w
 */

import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 20,
  duration: '60s',
};

// Validate required env vars once before VUs start
export function setup() {
  if (!__ENV.TOKEN) {
    throw new Error('TOKEN env var is required. Run: k6 run -e TOKEN=$(cat infra/jwt/token.jwt) ...');
  }
  if (!__ENV.GW_IP) {
    throw new Error(
      'GW_IP env var is required. Run: k6 run -e GW_IP=$(kubectl get svc istio-ingressgateway ' +
      '-n istio-system -o jsonpath=\'{.status.loadBalancer.ingress[0].ip}\') ...'
    );
  }
  return { token: __ENV.TOKEN, gwIP: __ENV.GW_IP };
}

export default function (data) {
  const url = `http://${data.gwIP}/anything`;

  const params = {
    headers: {
      // Gateway routes based on Host header (VirtualService host: service-1.local)
      'Host': 'service-1.local',
      // JWT required by RequestAuthentication + AuthorizationPolicy
      'Authorization': `Bearer ${data.token}`,
      'Content-Type': 'application/json',
    },
  };

  const payload = JSON.stringify({ source: 'k6-load-test', vu: __VU, iter: __ITER });

  const res = http.post(url, payload, params);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'no 401 (JWT rejected)': (r) => r.status !== 401,
    'no 403 (authz denied)': (r) => r.status !== 403,
  });

  // 0.5s sleep → 2 req/s per VU × 20 VUs = ~40 req/s total
  // Threshold is 5 req/s/replica → ceil(40/5) = 8 → clamped to maxReplicaCount=5
  sleep(0.5);
}
