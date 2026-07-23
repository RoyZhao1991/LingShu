use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const KERNEL_ABI_VERSION: &str = "1.0.0";
pub const KERNEL_CONTRACT_JSON: &str = include_str!("../resources/kernel-contract.json");

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KernelInterfaceContract {
    pub symbol: String,
    pub role: String,
    pub frozen_surface: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlatformCapabilities {
    pub computer_control: bool,
    pub realtime_perception: bool,
    pub internal_preview: bool,
    pub external_open: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KernelContract {
    pub abi_version: String,
    pub product: String,
    pub state_schema_version: u32,
    pub contracts: Vec<KernelInterfaceContract>,
    pub goal_spec_fields: Vec<String>,
    pub provider_protocols: Vec<String>,
    pub runtime_features: Vec<String>,
    pub platform_capabilities: BTreeMap<String, PlatformCapabilities>,
}

pub fn kernel_contract() -> KernelContract {
    let contract: KernelContract = serde_json::from_str(KERNEL_CONTRACT_JSON)
        .expect("embedded LingShu kernel contract must be valid JSON");
    debug_assert_eq!(contract.abi_version, KERNEL_ABI_VERSION);
    contract
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_contract_matches_compiled_abi() {
        let contract = kernel_contract();
        assert_eq!(contract.abi_version, KERNEL_ABI_VERSION);
        assert_eq!(contract.contracts.len(), 5);
        assert_eq!(contract.contracts[0].symbol, "LingShuAgentSessioning");
        assert_eq!(contract.goal_spec_fields.len(), 12);
        assert!(!contract.platform_capabilities["windows"].computer_control);
        assert!(contract.platform_capabilities["windows"].internal_preview);
    }
}
