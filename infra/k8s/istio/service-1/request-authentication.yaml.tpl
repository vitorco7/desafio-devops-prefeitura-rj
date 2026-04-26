# RequestAuthentication — validates JWT tokens on inbound requests to service-1.
#
# THIS IS A TEMPLATE. JWKS_INLINE is substituted by bootstrap.sh at apply time.
# kubectl apply -R will ignore this file (.yaml.tpl extension).
#
# How bootstrap.sh applies this:
#   python3 -c "
#     import json, sys
#     tpl = open(sys.argv[1]).read()
#     jwks = json.dumps(json.load(open(sys.argv[2])))
#     print(tpl.replace('JWKS_INLINE', jwks))
#   " this-file infra/jwt/jwks.json | kubectl apply -f -
#
# Behaviour:
#   - Requests WITH a valid JWT (iss=cluster.local, sig verifies) → pass, principal set
#   - Requests WITH an invalid/expired JWT → 401 immediately
#   - Requests WITHOUT a token → pass (principal unset); AuthorizationPolicy enforces denial
#
# JWKS_INLINE is a single-line compact JSON string — the inline form of the RSA
# public key used to verify RS256 signatures. istiod reads it directly from this
# Kubernetes object; no HTTP server is needed.

apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: service-1
spec:
  selector:
    matchLabels:
      app: service-1
  jwtRules:
  - issuer: "cluster.local"
    jwks: 'JWKS_INLINE'
