import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  stages: [
    { duration: '10s', target: 15 },
    { duration: '20s', target: 15 }
  ],
  thresholds: {
    http_req_duration: ['p(95)<250'],
  },
};

export default function () {
  const resFast = http.get(`${__ENV.MY_HOSTNAME}/fastapi`);
  const resSlow = http.get(`${__ENV.MY_HOSTNAME}/slowapi`);

  sleep(1);
}
