# care-abdm frontend (module-federation remote) served by nginx.
# Build context is this directory; the plug source is fetched by BuildKit at
# the pinned commit (pass the same SHA the backend pins in
# k8s/care/additional-plugs.json, so FE and BE halves never drift):
#   just care-abdm-fe-image
# Adapted from ohcnetwork/care_create@reference web/Dockerfile.

FROM node:22-bookworm-slim AS build
ARG CARE_ABDM_REF
ADD https://github.com/ohcnetwork/care-abdm.git#${CARE_ABDM_REF} /src
WORKDIR /src/frontend
# --base must equal the path the Ingress routes to this pod: the federation
# runtime resolves chunk/CSS URLs against it. Kept under /mfe-plugs/ because
# the plug's own SPA routes live at /abdm/... and must fall through to care_fe.
RUN npm ci --ignore-scripts && npx tsc -b && npx vite build --base=/mfe-plugs/abdm/

FROM nginx:stable-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/frontend/dist /usr/share/nginx/html/mfe-plugs/abdm
