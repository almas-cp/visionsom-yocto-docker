# Remove ntp so that chrony can be installed without package conflict (RCONFLICTS: chrony conflicts with ntp)
RDEPENDS:packagegroup-framework-tools-base-core:remove = "ntp"
