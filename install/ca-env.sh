# Sourced by setup.sh, install-tools.sh and install/security-fixes.sh: make
# everything they start use the trust store security-fixes.sh checked,
# whatever the environment says. Unlike .bashrc.d/10-ca-bundle.sh, this
# overrides existing settings, and covers curl's and git's built-in CA
# directories, which can still hold the compromised roots.
_ca_dir=${XDG_DATA_HOME:-$HOME/.local/share}/configs
if [ -s "$_ca_dir/ca-bundle.pem" ]; then
  export SSL_CERT_FILE="$_ca_dir/ca-bundle.pem" REQUESTS_CA_BUNDLE="$_ca_dir/ca-bundle.pem"
  export CURL_CA_BUNDLE="$_ca_dir/ca-bundle.pem" SSL_CERT_DIR="$_ca_dir/no-ca-dir"
  export GIT_SSL_CAINFO="$_ca_dir/ca-bundle.pem" GIT_SSL_CAPATH="$_ca_dir/no-ca-dir"
  [ -s "$_ca_dir/curl/.curlrc" ] && export CURL_HOME="$_ca_dir/curl"
fi
unset _ca_dir
