local tenants = import '../../tenants.libsonnet';
local k = import 'ksonnet/ksonnet.beta.4/k.libsonnet';
local list = import 'telemeter/lib/list.libsonnet';

local service = k.core.v1.service;
local configmap = k.core.v1.configMap;
local secret = k.core.v1.secret;
local sts = k.apps.v1.statefulSet;
local deployment = k.apps.v1.deployment;
local serviceAccount = k.core.v1.serviceAccount;
local role = k.rbac.v1.role;
local roleBinding = k.rbac.v1.roleBinding;
local clusterRole = k.rbac.v1.clusterRole;
local policyRule = clusterRole.rulesType;
local clusterRoleBinding = k.rbac.v1.clusterRoleBinding;

(import '../kubernetes/kube-thanos.libsonnet') +
{
  thanos+:: {
    local namespace = '${NAMESPACE}',
    namespace:: namespace,
    image:: '${THANOS_IMAGE}:${THANOS_IMAGE_TAG}',
    imageJaegerAgent:: '${JAEGER_AGENT_IMAGE}:${JAEGER_AGENT_IMAGE_TAG}',
    proxyImage:: '${PROXY_IMAGE}:${PROXY_IMAGE_TAG}',
    thanosReceiveControllerImage:: '${THANOS_RECEIVE_CONTROLLER_IMAGE}:${THANOS_RECEIVE_CONTROLLER_IMAGE_TAG}',
    objectStorageConfig+:: {
      name: '${THANOS_CONFIG_SECRET}',
      key: 'thanos.yaml',
    },
    proxyConfig+:: {
      sessionSecret: '',
    },

    local s3Envvars = {
      spec+: {
        containers: [
          local container = sts.mixin.spec.template.spec.containersType;
          local env = container.envType;

          if
            c.name == $.thanos.querier.deployment.metadata.name ||
            c.name == $.thanos.store.statefulSet.metadata.name ||
            c.name == $.thanos.compactor.statefulSet.metadata.name ||
            c.name == $.thanos.ruler.statefulSet.metadata.name ||
            c.name == $.thanos.receive.statefulSet.metadata.name
          then c {
            env+: [
              env.fromSecretRef('AWS_ACCESS_KEY_ID', '${THANOS_S3_SECRET}', 'aws_access_key_id'),
              env.fromSecretRef('AWS_SECRET_ACCESS_KEY', '${THANOS_S3_SECRET}', 'aws_secret_access_key'),
            ],
          } else c
          for c in super.containers
        ],
      },
    },

    querier+: {
      externalPrefix:: '/ui/v1/metrics',

      // The proxy secret is there to encrypt session created by the oauth proxy.
      proxySecret:
        secret.new('querier-proxy', {
          session_secret: std.base64($.thanos.proxyConfig.sessionSecret),
        }) +
        secret.mixin.metadata.withNamespace(namespace) +
        secret.mixin.metadata.withLabels({ 'app.kubernetes.io/name': 'thanos-querier' }),

      service+:
        service.mixin.metadata.withNamespace(namespace) +
        service.mixin.metadata.withAnnotations({
          'service.alpha.openshift.io/serving-cert-secret-name': 'querier-tls',
        }) + {
          spec+: {
            ports+: [
              service.mixin.spec.portsType.newNamed('https', 9091, 'https'),
            ],
          },
        },
      local volume = deployment.mixin.spec.template.spec.volumesType,
      local container = deployment.mixin.spec.template.spec.containersType,
      local volumeMount = container.volumeMountsType,
      deployment+:
        {
          spec+: {
            template+: {
              spec+: {
                containers: [
                  if c.name == 'thanos-querier' then c {
                    resources: {
                      requests: {
                        cpu: '${THANOS_QUERIER_CPU_REQUEST}',
                        memory: '${THANOS_QUERIER_MEMORY_REQUEST}',
                      },
                      limits: {
                        cpu: '${THANOS_QUERIER_CPU_LIMIT}',
                        memory: '${THANOS_QUERIER_MEMORY_LIMIT}',
                      },
                    },
                  } else c
                  for c in super.containers
                ] + [
                  container.new('proxy', $.thanos.proxyImage) +
                  container.withArgs([
                    '-provider=openshift',
                    '-https-address=:%d' % $.thanos.querier.service.spec.ports[2].port,
                    '-http-address=',
                    '-email-domain=*',
                    '-upstream=http://localhost:%d' % $.thanos.querier.service.spec.ports[1].port,
                    '-openshift-service-account=prometheus-telemeter',
                    '-openshift-sar={"resource": "namespaces", "verb": "get", "name": "${NAMESPACE}", "namespace": "${NAMESPACE}"}',
                    '-openshift-delegate-urls={"/": {"resource": "namespaces", "verb": "get", "name": "${NAMESPACE}", "namespace": "${NAMESPACE}"}}',
                    '-tls-cert=/etc/tls/private/tls.crt',
                    '-tls-key=/etc/tls/private/tls.key',
                    '-client-secret-file=/var/run/secrets/kubernetes.io/serviceaccount/token',
                    '-cookie-secret-file=/etc/proxy/secrets/session_secret',
                    '-openshift-ca=/etc/pki/tls/cert.pem',
                    '-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                    '-skip-auth-regex=^/metrics',
                  ]) +
                  container.withPorts([
                    { name: 'https', containerPort: $.thanos.querier.service.spec.ports[2].port },
                  ]) +
                  container.withVolumeMounts(
                    [
                      volumeMount.new('secret-querier-tls', '/etc/tls/private'),
                      volumeMount.new('secret-querier-proxy', '/etc/proxy/secrets'),
                    ]
                  ) +
                  container.mixin.resources.withRequests({
                    cpu: '${JAEGER_PROXY_CPU_REQUEST}',
                    memory: '${JAEGER_PROXY_MEMORY_REQUEST}',
                  }) +
                  container.mixin.resources.withLimits({
                    cpu: '${JAEGER_PROXY_CPU_LIMITS}',
                    memory: '${JAEGER_PROXY_MEMORY_LIMITS}',
                  }),
                ],
              },
            },
          },
        } +
        deployment.mixin.metadata.withNamespace(namespace) +
        deployment.mixin.spec.withReplicas('${{THANOS_QUERIER_REPLICAS}}') +
        deployment.mixin.spec.template.spec.withServiceAccount('prometheus-telemeter') +
        deployment.mixin.spec.template.spec.withServiceAccountName('prometheus-telemeter') +
        deployment.mixin.spec.template.spec.withVolumes([
          volume.fromSecret('secret-querier-tls', 'querier-tls'),
          volume.fromSecret('secret-querier-proxy', 'querier-proxy'),
        ]),
    },

    store+: {
      pvc+:: {
        class: 'gp2-encrypted',
        size: '50Gi',
      },
      statefulSet+: {
        spec+: {
          replicas: '${{THANOS_STORE_REPLICAS}}',

          // As we use Vault and want to be able to use rotation of credentials,
          // we need to provide the AWS key and secret via envvars, cause the thanos.yaml is written by hand.
          template+: s3Envvars {
            spec+: {
              containers: [
                local container = sts.mixin.spec.template.spec.containersType;
                local env = container.envType;

                if c.name == 'thanos-store' then c {
                  resources: {
                    requests: {
                      cpu: '${THANOS_STORE_CPU_REQUEST}',
                      memory: '${THANOS_STORE_MEMORY_REQUEST}',
                    },
                    limits: {
                      cpu: '${THANOS_STORE_CPU_LIMIT}',
                      memory: '${THANOS_STORE_MEMORY_LIMIT}',
                    },
                  },
                } else c
                for c in super.containers
              ],
            },
          },
        },
      },
    },

    compactor+: {
      service+:
        service.mixin.metadata.withNamespace(namespace),
      statefulSet+: {
        metadata+: {
          namespace: namespace,
        },
        spec+: {
          replicas: '${{THANOS_COMPACTOR_REPLICAS}}',

          // As we use Vault and want to be able to use rotation of credentials,
          // we need to provide the AWS key and secret via envvars, cause the thanos.yaml is written by hand.
          template+: s3Envvars {
            spec+: {
              containers: [
                local container = sts.mixin.spec.template.spec.containersType;
                local env = container.envType;

                if c.name == 'thanos-compactor' then c {
                  resources: {
                    requests: {
                      cpu: '${THANOS_COMPACTOR_CPU_REQUEST}',
                      memory: '${THANOS_COMPACTOR_MEMORY_REQUEST}',
                    },
                    limits: {
                      cpu: '${THANOS_COMPACTOR_CPU_LIMIT}',
                      memory: '${THANOS_COMPACTOR_MEMORY_LIMIT}',
                    },
                  },
                } else c
                for c in super.containers
              ],
            },
          },
        },
      },
    },

    ruler+: {
      local tr = $.thanos.ruler,
      ruleFiles:: [
        '/var/thanos/config/ruler/telemeter-rules.yaml',
      ],
      service+:
        service.mixin.metadata.withNamespace(namespace),
      statefulSet+: {
        metadata+: {
          namespace: namespace,
        },
        spec+: {
          replicas: '${{THANOS_RULER_REPLICAS}}',

          // As we use Vault and want to be able to use rotation of credentials,
          // we need to provide the AWS key and secret via envvars, cause the thanos.yaml is written by hand.
          template+: s3Envvars {
            local volume = sts.mixin.spec.template.spec.volumesType,
            local item = sts.mixin.spec.template.spec.volumesType.mixin.configMapType.itemsType,
            spec+: {
              containers: [
                local container = sts.mixin.spec.template.spec.containersType;
                local volumeMount = container.volumeMountsType;
                local env = container.envType;

                if c.name == 'thanos-ruler' then c {
                  resources: {
                    requests: {
                      cpu: '${THANOS_RULER_CPU_REQUEST}',
                      memory: '${THANOS_RULER_MEMORY_REQUEST}',
                    },
                    limits: {
                      cpu: '${THANOS_RULER_CPU_LIMIT}',
                      memory: '${THANOS_RULER_MEMORY_LIMIT}',
                    },
                  },

                  volumeMounts+: [
                    volumeMount.new(tr.configmap.metadata.name, '/var/thanos/config/ruler', true),
                  ],
                }
                else c
                for c in super.containers
              ],
              volumes+: [
                volume.fromConfigMap('telemeter-rules-config', tr.configmap.metadata.name) {
                  configMap+: { items:: null },
                },
              ],
            },
          },
        },
      },
      configmap:
        local configmap = k.core.v1.configMap;

        configmap.new() +
        configmap.mixin.metadata.withName('telemeter-rules-config') +
        configmap.mixin.metadata.withNamespace(namespace) +
        configmap.mixin.metadata.withLabels($.thanos.ruler.labels) +
        configmap.withData({
          local rules = (import 'telemeter/rules.libsonnet'),

          'telemeter-rules.yaml': std.manifestYamlDoc(rules.prometheus.recordingrules),
        }),
    },

    receive+: {
      pvc+:: {
        class: 'gp2-encrypted',
      },

      service+: service.mixin.metadata.withNamespace(namespace),
    } + {
      ['service-' + tenant.hashring]+: service.mixin.metadata.withNamespace(namespace)
      for tenant in tenants
    } + {
      ['statefulSet-' + tenant.hashring]+: {
        metadata+: {
          namespace: namespace,
        },
        spec+: {
          replicas: '${{THANOS_RECEIVE_REPLICAS}}',

          // As we use Vault and want to be able to use rotation of credentials,
          // we need to provide the AWS key and secret via envvars, cause the thanos.yaml is written by hand.
          template+: s3Envvars {
            spec+: {
              containers: [
                local container = sts.mixin.spec.template.spec.containersType;
                local env = container.envType;
                if c.name == 'thanos-receive' then c {
                  resources: {
                    requests: {
                      cpu: '${THANOS_RECEIVE_CPU_REQUEST}',
                      memory: '${THANOS_RECEIVE_MEMORY_REQUEST}',
                    },
                    limits: {
                      cpu: '${THANOS_RECEIVE_CPU_LIMIT}',
                      memory: '${THANOS_RECEIVE_MEMORY_LIMIT}',
                    },
                  },
                } else c
                for c in super.containers
              ],
            },
          },
        },
      }
      for tenant in tenants
    },

    receiveController+: {
      local setSubjectNamespace(object) = {
        subjects: [
          s { namespace: '${NAMESPACE}' }
          for s in super.subjects
        ],
      },
      configmap+:
        configmap.mixin.metadata.withNamespace(namespace),
      serviceAccount+:
        serviceAccount.mixin.metadata.withNamespace(namespace),
      service+:
        service.mixin.metadata.withNamespace(namespace),
      serviceMonitor+: {
        metadata+: {
          namespace: namespace,
        },
      },
      deployment+:
        deployment.mixin.metadata.withNamespace(namespace) + {
          spec+: {
            template+: {
              spec+: {
                containers: [
                  super.containers[0] {
                    image: $.thanos.thanosReceiveControllerImage,
                  },
                ],
              },
            },
          },
        },
      role+:
        role.mixin.metadata.withNamespace(namespace),
      roleBinding+: setSubjectNamespace(super.roleBinding) + roleBinding.mixin.metadata.withNamespace(namespace),
    },

    querierCache+: {
      // The proxy secret is there to encrypt session created by the oauth proxy.
      proxySecret:
        secret.new('querier-cache-proxy', {
          session_secret: std.base64($.thanos.proxyConfig.sessionSecret),
        }) +
        secret.mixin.metadata.withNamespace(namespace) +
        secret.mixin.metadata.withLabels({ 'app.kubernetes.io/name': 'thanos-querier' }),
      configmap+:
        configmap.mixin.metadata.withNamespace(namespace),
      service+:
        service.mixin.metadata.withNamespace(namespace) +
        service.mixin.metadata.withAnnotations({
          'service.alpha.openshift.io/serving-cert-secret-name': 'querier-cache-tls',
        }) + {
          spec+: {
            ports+: [
              service.mixin.spec.portsType.newNamed('proxy', 9091, 'https'),
            ],
          },
        },

      local volume = deployment.mixin.spec.template.spec.volumesType,
      local container = deployment.mixin.spec.template.spec.containersType,
      local volumeMount = container.volumeMountsType,
      deployment+:
        {
          spec+: {
            template+: {
              spec+: {
                containers: [
                  super.containers[0] {
                    resources: {
                      requests: {
                        cpu: '${THANOS_QUERIER_CACHE_CPU_REQUEST}',
                        memory: '${THANOS_QUERIER_CACHE_MEMORY_REQUEST}',
                      },
                      limits: {
                        cpu: '${THANOS_QUERIER_CACHE_CPU_LIMIT}',
                        memory: '${THANOS_QUERIER_CACHE_MEMORY_LIMIT}',
                      },
                    },
                  },
                ] + [
                  container.new('proxy', $.thanos.proxyImage) +
                  container.withArgs([
                    '-provider=openshift',
                    '-https-address=:%d' % $.thanos.querierCache.service.spec.ports[1].port,
                    '-http-address=',
                    '-email-domain=*',
                    '-upstream=http://localhost:%d' % $.thanos.querierCache.service.spec.ports[0].port,
                    '-openshift-service-account=prometheus-telemeter',
                    '-openshift-sar={"resource": "namespaces", "verb": "get", "name": "${NAMESPACE}", "namespace": "${NAMESPACE}"}',
                    '-openshift-delegate-urls={"/": {"resource": "namespaces", "verb": "get", "name": "${NAMESPACE}", "namespace": "${NAMESPACE}"}}',
                    '-tls-cert=/etc/tls/private/tls.crt',
                    '-tls-key=/etc/tls/private/tls.key',
                    '-client-secret-file=/var/run/secrets/kubernetes.io/serviceaccount/token',
                    '-cookie-secret-file=/etc/proxy/secrets/session_secret',
                    '-openshift-ca=/etc/pki/tls/cert.pem',
                    '-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                    '-skip-auth-regex=^/metrics',
                  ]) +
                  container.withPorts([
                    { name: 'https', containerPort: $.thanos.querier.service.spec.ports[2].port },
                  ]) +
                  container.mixin.resources.withRequests({ cpu: '32m', memory: '32Mi' }) +
                  container.mixin.resources.withLimits({ cpu: '64m', memory: '128Mi' }) +
                  container.withVolumeMounts(
                    [
                      volumeMount.new('secret-querier-cache-tls', '/etc/tls/private'),
                      volumeMount.new('secret-querier-cache-proxy', '/etc/proxy/secrets'),
                    ]
                  ) +
                  container.mixin.resources.withRequests({
                    cpu: '${JAEGER_PROXY_CPU_REQUEST}',
                    memory: '${JAEGER_PROXY_MEMORY_REQUEST}',
                  }) +
                  container.mixin.resources.withLimits({
                    cpu: '${JAEGER_PROXY_CPU_LIMITS}',
                    memory: '${JAEGER_PROXY_MEMORY_LIMITS}',
                  }),
                ],
                volumes+: [
                  volume.fromSecret('secret-querier-cache-tls', 'querier-cache-tls'),
                  volume.fromSecret('secret-querier-cache-proxy', 'querier-cache-proxy'),
                ],
              },
            },
          },
        } +
        deployment.mixin.metadata.withNamespace(namespace) +
        deployment.mixin.spec.template.spec.withServiceAccount('prometheus-telemeter') +
        deployment.mixin.spec.template.spec.withServiceAccountName('prometheus-telemeter'),
    },
  },
} + {
  apiVersion: 'v1',
  kind: 'Template',
  metadata: {
    name: 'observatorium-thanos',
  },
  objects: [
    $.thanos.querier[name]
    for name in std.objectFields($.thanos.querier)
  ] + [
    $.thanos.store[name]
    for name in std.objectFields($.thanos.store)
  ] + [
    $.thanos.compactor[name]
    for name in std.objectFields($.thanos.compactor)
  ] + [
    $.thanos.receive[name]
    for name in std.objectFields($.thanos.receive)
  ] + [
    $.thanos.receiveController[name]
    for name in std.objectFields($.thanos.receiveController)
  ] + [
    $.thanos.querierCache[name]
    for name in std.objectFields($.thanos.querierCache)
  ] + [
    $.thanos.ruler[name]
    for name in std.objectFields($.thanos.ruler)
  ] + [
    $.thanos.rules[name]
    for name in std.objectFields($.thanos.rules)
  ],
  parameters: [
    { name: 'NAMESPACE', value: 'telemeter' },
    { name: 'THANOS_IMAGE', value: 'quay.io/thanos/thanos' },
    { name: 'THANOS_IMAGE_TAG', value: 'v0.9.0' },
    { name: 'PROXY_IMAGE', value: 'openshift/oauth-proxy' },
    { name: 'PROXY_IMAGE_TAG', value: 'v1.1.0' },
    { name: 'JAEGER_AGENT_IMAGE', value: 'jaegertracing/jaeger-agent' },
    { name: 'JAEGER_AGENT_IMAGE_TAG', value: '1.14.0' },
    { name: 'THANOS_RECEIVE_CONTROLLER_IMAGE', value: 'quay.io/observatorium/thanos-receive-controller' },
    { name: 'THANOS_RECEIVE_CONTROLLER_IMAGE_TAG', value: 'master-2019-10-18-d55fee2' },
    { name: 'THANOS_QUERIER_REPLICAS', value: '3' },
    { name: 'THANOS_STORE_REPLICAS', value: '5' },
    { name: 'THANOS_COMPACTOR_REPLICAS', value: '1' },
    { name: 'THANOS_RECEIVE_REPLICAS', value: '5' },
    { name: 'THANOS_CONFIG_SECRET', value: 'thanos-objectstorage' },
    { name: 'THANOS_S3_SECRET', value: 'telemeter-thanos-stage-s3' },
    { name: 'THANOS_QUERIER_CPU_REQUEST', value: '100m' },
    { name: 'THANOS_QUERIER_CPU_LIMIT', value: '1' },
    { name: 'THANOS_QUERIER_MEMORY_REQUEST', value: '256Mi' },
    { name: 'THANOS_QUERIER_MEMORY_LIMIT', value: '1Gi' },
    { name: 'THANOS_QUERIER_CACHE_CPU_REQUEST', value: '100m' },
    { name: 'THANOS_QUERIER_CACHE_CPU_LIMIT', value: '1' },
    { name: 'THANOS_QUERIER_CACHE_MEMORY_REQUEST', value: '256Mi' },
    { name: 'THANOS_QUERIER_CACHE_MEMORY_LIMIT', value: '1Gi' },
    { name: 'THANOS_STORE_CPU_REQUEST', value: '500m' },
    { name: 'THANOS_STORE_CPU_LIMIT', value: '2' },
    { name: 'THANOS_STORE_MEMORY_REQUEST', value: '1Gi' },
    { name: 'THANOS_STORE_MEMORY_LIMIT', value: '8Gi' },
    { name: 'THANOS_RECEIVE_CPU_REQUEST', value: '100m' },
    { name: 'THANOS_RECEIVE_CPU_LIMIT', value: '1' },
    { name: 'THANOS_RECEIVE_MEMORY_REQUEST', value: '512Mi' },
    { name: 'THANOS_RECEIVE_MEMORY_LIMIT', value: '1Gi' },
    { name: 'THANOS_COMPACTOR_CPU_REQUEST', value: '100m' },
    { name: 'THANOS_COMPACTOR_CPU_LIMIT', value: '1' },
    { name: 'THANOS_COMPACTOR_MEMORY_REQUEST', value: '1Gi' },
    { name: 'THANOS_COMPACTOR_MEMORY_LIMIT', value: '5Gi' },
    { name: 'THANOS_RULER_REPLICAS', value: '2' },
    { name: 'THANOS_RULER_CPU_REQUEST', value: '100m' },
    { name: 'THANOS_RULER_CPU_LIMIT', value: '1' },
    { name: 'THANOS_RULER_MEMORY_REQUEST', value: '512Mi' },
    { name: 'THANOS_RULER_MEMORY_LIMIT', value: '1Gi' },
    { name: 'THANOS_QUERIER_SVC_URL', value: 'http://thanos-querier.observatorium.svc:9090' },
    { name: 'JAEGER_PROXY_CPU_REQUEST', value: '100m' },
    { name: 'JAEGER_PROXY_MEMORY_REQUEST', value: '100Mi' },
    { name: 'JAEGER_PROXY_CPU_LIMITS', value: '200m' },
    { name: 'JAEGER_PROXY_MEMORY_LIMITS', value: '200Mi' },
  ],
}
