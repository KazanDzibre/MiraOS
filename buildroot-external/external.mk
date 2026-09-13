# Pull in every Mira package definition.
include $(sort $(wildcard $(BR2_EXTERNAL_MIRA_PATH)/package/*/*.mk))
