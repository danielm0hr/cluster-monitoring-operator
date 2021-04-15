local k = import 'ksonnet/ksonnet.beta.3/k.libsonnet';
local service = k.core.v1.service;
local deployment = k.apps.v1beta2.deployment;
local container = deployment.mixin.spec.template.spec.containersType;
local volume = deployment.mixin.spec.template.spec.volumesType;
local configmap = k.core.v1.configMap;
local containerPort = container.portsType;
local containerVolumeMount = container.volumeMountsType;
local tmpVolumeName = 'volume-directive-shadow';
local tlsVolumeName = 'kube-state-metrics-tls';

{
  kubeStateMetrics+:: {
    namespace:: 'openshift-monitoring',
    // Adding the serving certs annotation causes the serving certs controller
    // to generate a valid and signed serving certificate and put it in the
    // specified secret.

    service+:
      service.mixin.metadata.withAnnotations({
        'service.beta.openshift.io/serving-cert-secret-name': 'kube-state-metrics-tls',
      }),

    // This changes kube-state-metrics to be scraped with validating TLS.

    serviceMonitor+:
      {
        spec+: {
          endpoints: [
            {
              bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
              honorLabels: true,
              interval: '1m',
              scrapeTimeout: '1m',
              port: 'https-main',
              scheme: 'https',
              tlsConfig: {
                caFile: '/etc/prometheus/configmaps/serving-certs-ca-bundle/service-ca.crt',
                serverName: 'server-name-replaced-at-runtime',
              },
              // Drop the "instance" and "pod" labels since we're runinng only
              // one instance of kube-state-metrics. The "instance" label must be
              // dropped at the metrics relabeling stage (instead of the service
              // discovery stage) because otherwise Prometheus will default its
              // value to the address being scraped.
              // The net result is to avoid excessive series churn when
              // kube-state-metrics is redeployed because of node reboot, pod
              // rescheduling or cluster upgrade.
              metricRelabelings: [
                {
                  action: 'labeldrop',
                  regex: 'instance',
                },
              ],
              relabelings: [
                {
                  action: 'labeldrop',
                  regex: 'pod',
                },
              ],
            },
            {
              bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
              interval: '1m',
              scrapeTimeout: '1m',
              port: 'https-self',
              scheme: 'https',
              tlsConfig: {
                caFile: '/etc/prometheus/configmaps/serving-certs-ca-bundle/service-ca.crt',
                serverName: 'server-name-replaced-at-runtime',
              },
            },
          ],
        },
      },

    // This removes the upstream addon-resizer and all resource requests and
    // limits. Additionally configures the kube-rbac-proxies to use the serving
    // cert configured on the `Service` above.
    //
    // The upstream kube-state-metrics Dockerfile defines a `VOLUME` directive
    // in `/tmp`. Although this is unused it will take some time for it to get
    // released, which is why it is shadowed here for the time being.

    deployment+:
      {
        spec+: {
          template+: {
            spec+: {
              containers:
                std.filterMap(
                  function(c) c.name != 'addon-resizer',
                  function(c)
                    if std.startsWith(c.name, 'kube-rbac-proxy') then
                      c {
                        args+: [
                          '--tls-cert-file=/etc/tls/private/tls.crt',
                          '--tls-private-key-file=/etc/tls/private/tls.key',
                        ],
                        terminationMessagePolicy: 'FallbackToLogsOnError',
                        volumeMounts: [
                          containerVolumeMount.new(tlsVolumeName, '/etc/tls/private'),
                        ],
                        securityContext: {},
                        resources: {
                          requests: {
                            memory: '40Mi',
                            cpu: '1m',
                          },
                        },
                      }
                    else
                      c +
                      container.withVolumeMounts([containerVolumeMount.new(tmpVolumeName, '/tmp')]) +
                      {
                        args+: [
                          '--metric-blacklist=kube_secret_labels',
                        ],
                        securityContext: {},
                        resources: {
                          requests: {
                            memory: '40Mi',
                            cpu: '2m',
                          },
                        },
                      },
                  super.containers,
                ),
              volumes+: [
                volume.fromEmptyDir(tmpVolumeName),
                volume.fromSecret(tlsVolumeName, 'kube-state-metrics-tls'),
              ],
              securityContext: {},
              priorityClassName: 'system-cluster-critical',
            },
          },
        },
      },
  },
}
