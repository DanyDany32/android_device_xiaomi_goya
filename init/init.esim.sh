#!/vendor/bin/sh
STATE=$(/vendor/bin/mtkmtb -c 5:4)
setprop vendor.esim.state "$STATE"
