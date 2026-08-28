{
  description = "Noctalia v5 Elgato Control plugin";

  outputs = { self }: {
    nixosModules.default = { ... }: {
      services.udev.extraRules = ''
        KERNEL=="hidraw*", ATTRS{idVendor}=="0fd9", TAG+="uaccess", MODE="0660", GROUP="input"
        SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", TAG+="uaccess", MODE="0660"
      '';
    };
  };
}
