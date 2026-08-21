"""Configuration: load a Flyte config.yaml and expose it as a struct."""
from ._state import state


@fieldwise_init
struct Config(ImplicitlyCopyable, Writable):
    var path: String
    var endpoint: String
    var org: String
    var project: String
    var domain: String
    var image_builder: String


def init_from_config(path: String = "") raises -> Config:
    """Load a Flyte config (default: ``~/.flyte/config.yaml``).

    The config is stored in the SDK state so that remote runs use the
    same endpoint/org/project/domain. Returns the parsed values.
    """
    var st = state()
    var cfg = st.config_load(path)
    st.config_set_path(path)
    var endpoint = String(cfg["endpoint"])
    var org = String(cfg["org"])
    var project = String(cfg["project"])
    var domain = String(cfg["domain"])
    var image_builder = String(cfg["image_builder"])
    return Config(path, endpoint, org, project, domain, image_builder)
