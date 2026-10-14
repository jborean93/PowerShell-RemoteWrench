using module ../output/RemoteWrench
using namespace System.IO

BeforeAll { . ([Path]::Combine($PSScriptRoot, 'common.ps1')) }

Describe "ConvertTo-PSRPPacket" {
    It "Parses packet with single message" {
        $packet = "<Data Stream='Default' PSGuid='6e6e7727-08b7-4440-855f-6e417c17511c'>AAAAAAAAAAQAAAAAAAAAAAMAAABnAQAAAAYQBACvXvqm+i4+S4Bve+JSo5vpJ3dubrcIQESFX25BfBdRHO+7vzxPYmogUmVmSWQ9IjAiPjxNUz48STMyIE49IlBpcGVsaW5lU3RhdGUiPjQ8L0kzMj48L01TPjwvT2JqPg==</Data>" |
            ConvertTo-PSRPPacket

        $packet.Type | Should-Be Data
        $packet.PSGuid | Should-Be "6e6e7727-08b7-4440-855f-6e417c17511c"
        $packet.Stream | Should-Be "Default"

        $packet.Fragments | Should-BeCollection -Count 1
        $packet.Fragments[0].ObjectId | Should-Be 4
        $packet.Fragments[0].FragmentId | Should-Be 0
        $packet.Fragments[0].Start | Should-BeTrue
        $packet.Fragments[0].End | Should-BeTrue

        $packet.Messages | Should-BeCollection -Count 1
        $packet.Messages[0].Destination | Should-Be Client
        $packet.Messages[0].MessageType | Should-Be PipelineState
        $packet.Messages[0].RunspacePoolId | Should-Be "a6fa5eaf-2efa-4b3e-806f-7be252a39be9"
        $packet.Messages[0].PipelineId | Should-Be "6e6e7727-08b7-4440-855f-6e417c17511c"
        $packet.Messages[0].Data | Should-BeLikeString '<Obj RefId="0">*'

        $packet.Raw | Should-BeLikeString "<Data Stream='Default' PSGuid='6e6e7727-08b7-4440-855f-6e417c17511c'>*</Data>"
    }

    It "Parses packet with multiple messages" {
        $packet = "<Data Stream='Default' PSGuid='00000000-0000-0000-0000-000000000000'>AAAAAAAAAAEAAAAAAAAAAAMAAADKAgAAAAIAAQCvXvqm+i4+S4Bve+JSo5vpAAAAAAAAAAAAAAAAAAAAAO+7vzxPYmogUmVmSWQ9IjAiPjxNUz48VmVyc2lvbiBOPSJwcm90b2NvbHZlcnNpb24iPjIuMzwvVmVyc2lvbj48VmVyc2lvbiBOPSJQU1ZlcnNpb24iPjIuMDwvVmVyc2lvbj48VmVyc2lvbiBOPSJTZXJpYWxpemF0aW9uVmVyc2lvbiI+MS4xLjAuMTwvVmVyc2lvbj48L01TPjwvT2JqPgAAAAAAAAACAAAAAAAAAAADAAAO4AIAAAAEAAEAr176pvouPkuAb3viUqOb6QAAAAAAAAAAAAAAAAAAAADvu788T2JqIFJlZklkPSIwIj48TVM+PEkzMiBOPSJNaW5SdW5zcGFjZXMiPjE8L0kzMj48STMyIE49Ik1heFJ1bnNwYWNlcyI+MTwvSTMyPjxPYmogTj0iUFNUaHJlYWRPcHRpb25zIiBSZWZJZD0iMSI+PFROIFJlZklkPSIwIj48VD5TeXN0ZW0uTWFuYWdlbWVudC5BdXRvbWF0aW9uLlJ1bnNwYWNlcy5QU1RocmVhZE9wdGlvbnM8L1Q+PFQ+U3lzdGVtLkVudW08L1Q+PFQ+U3lzdGVtLlZhbHVlVHlwZTwvVD48VD5TeXN0ZW0uT2JqZWN0PC9UPjwvVE4+PFRvU3RyaW5nPkRlZmF1bHQ8L1RvU3RyaW5nPjxJMzI+MDwvSTMyPjwvT2JqPjxPYmogTj0iQXBhcnRtZW50U3RhdGUiIFJlZklkPSIyIj48VE4gUmVmSWQ9IjEiPjxUPlN5c3RlbS5UaHJlYWRpbmcuQXBhcnRtZW50U3RhdGU8L1Q+PFQ+U3lzdGVtLkVudW08L1Q+PFQ+U3lzdGVtLlZhbHVlVHlwZTwvVD48VD5TeXN0ZW0uT2JqZWN0PC9UPjwvVE4+PFRvU3RyaW5nPlVua25vd248L1RvU3RyaW5nPjxJMzI+MjwvSTMyPjwvT2JqPjxPYmogTj0iQXBwbGljYXRpb25Bcmd1bWVudHMiIFJlZklkPSIzIj48VE4gUmVmSWQ9IjIiPjxUPlN5c3RlbS5NYW5hZ2VtZW50LkF1dG9tYXRpb24uUFNQcmltaXRpdmVEaWN0aW9uYXJ5PC9UPjxUPlN5c3RlbS5Db2xsZWN0aW9ucy5IYXNodGFibGU8L1Q+PFQ+U3lzdGVtLk9iamVjdDwvVD48L1ROPjxEQ1Q+PEVuPjxTIE49IktleSI+UFNWZXJzaW9uVGFibGU8L1M+PE9iaiBOPSJWYWx1ZSIgUmVmSWQ9IjQiPjxUTlJlZiBSZWZJZD0iMiIgLz48RENUPjxFbj48UyBOPSJLZXkiPk9TPC9TPjxTIE49IlZhbHVlIj5GZWRvcmEgTGludXggNDMgKFNlcnZlciBFZGl0aW9uKTwvUz48L0VuPjxFbj48UyBOPSJLZXkiPkdpdENvbW1pdElkPC9TPjxTIE49IlZhbHVlIj43LjUuMTwvUz48L0VuPjxFbj48UyBOPSJLZXkiPlBTVmVyc2lvbjwvUz48VmVyc2lvbiBOPSJWYWx1ZSI+Ny41LjE8L1ZlcnNpb24+PC9Fbj48RW4+PFMgTj0iS2V5Ij5QU1JlbW90aW5nUHJvdG9jb2xWZXJzaW9uPC9TPjxWZXJzaW9uIE49IlZhbHVlIj4yLjM8L1ZlcnNpb24+PC9Fbj48RW4+PFMgTj0iS2V5Ij5TZXJpYWxpemF0aW9uVmVyc2lvbjwvUz48VmVyc2lvbiBOPSJWYWx1ZSI+MS4xLjAuMTwvVmVyc2lvbj48L0VuPjxFbj48UyBOPSJLZXkiPldTTWFuU3RhY2tWZXJzaW9uPC9TPjxWZXJzaW9uIE49IlZhbHVlIj4zLjA8L1ZlcnNpb24+PC9Fbj48RW4+PFMgTj0iS2V5Ij5QU0VkaXRpb248L1M+PFMgTj0iVmFsdWUiPkNvcmU8L1M+PC9Fbj48RW4+PFMgTj0iS2V5Ij5QU0NvbXBhdGlibGVWZXJzaW9uczwvUz48T2JqIE49IlZhbHVlIiBSZWZJZD0iNSI+PFROIFJlZklkPSIzIj48VD5TeXN0ZW0uVmVyc2lvbltdPC9UPjxUPlN5c3RlbS5BcnJheTwvVD48VD5TeXN0ZW0uT2JqZWN0PC9UPjwvVE4+PExTVD48VmVyc2lvbj4xLjA8L1ZlcnNpb24+PFZlcnNpb24+Mi4wPC9WZXJzaW9uPjxWZXJzaW9uPjMuMDwvVmVyc2lvbj48VmVyc2lvbj40LjA8L1ZlcnNpb24+PFZlcnNpb24+NS4wPC9WZXJzaW9uPjxWZXJzaW9uPjUuMTwvVmVyc2lvbj48VmVyc2lvbj42LjA8L1ZlcnNpb24+PFZlcnNpb24+Ny4wPC9WZXJzaW9uPjwvTFNUPjwvT2JqPjwvRW4+PEVuPjxTIE49IktleSI+UFNTZW1hbnRpY1ZlcnNpb248L1M+PFMgTj0iVmFsdWUiPjcuNS4xPC9TPjwvRW4+PEVuPjxTIE49IktleSI+UGxhdGZvcm08L1M+PFMgTj0iVmFsdWUiPlVuaXg8L1M+PC9Fbj48L0RDVD48L09iaj48L0VuPjwvRENUPjwvT2JqPjxPYmogTj0iSG9zdEluZm8iIFJlZklkPSI2Ij48TVM+PEIgTj0iX2lzSG9zdFVJTnVsbCI+ZmFsc2U8L0I+PEIgTj0iX2lzSG9zdFJhd1VJTnVsbCI+ZmFsc2U8L0I+PEIgTj0iX2lzSG9zdE51bGwiPmZhbHNlPC9CPjxPYmogTj0iX2hvc3REZWZhdWx0RGF0YSIgUmVmSWQ9IjciPjxNUz48T2JqIE49ImRhdGEiIFJlZklkPSI4Ij48VE4gUmVmSWQ9IjQiPjxUPlN5c3RlbS5Db2xsZWN0aW9ucy5IYXNodGFibGU8L1Q+PFQ+U3lzdGVtLk9iamVjdDwvVD48L1ROPjxEQ1Q+PEVuPjxJMzIgTj0iS2V5Ij45PC9JMzI+PE9iaiBOPSJWYWx1ZSIgUmVmSWQ9IjkiPjxNUz48UyBOPSJUIj5TeXN0ZW0uU3RyaW5nPC9TPjxTIE49IlYiPjwvUz48L01TPjwvT2JqPjwvRW4+PEVuPjxJMzIgTj0iS2V5Ij44PC9JMzI+PE9iaiBOPSJWYWx1ZSIgUmVmSWQ9IjEwIj48TVM+PFMgTj0iVCI+U3lzdGVtLk1hbmFnZW1lbnQuQXV0b21hdGlvbi5Ib3N0LlNpemU8L1M+PE9iaiBOPSJWIiBSZWZJZD0iMTEiPjxNUz48STMyIE49IndpZHRoIj4xNTY8L0kzMj48STMyIE49ImhlaWdodCI+MTc8L0kzMj48L01TPjwvT2JqPjwvTVM+PC9PYmo+PC9Fbj48RW4+PEkzMiBOPSJLZXkiPjc8L0kzMj48T2JqIE49IlZhbHVlIiBSZWZJZD0iMTIiPjxNUz48UyBOPSJUIj5TeXN0ZW0uTWFuYWdlbWVudC5BdXRvbWF0aW9uLkhvc3QuU2l6ZTwvUz48T2JqIE49IlYiIFJlZklkPSIxMyI+PE1TPjxJMzIgTj0id2lkdGgiPjE1NjwvSTMyPjxJMzIgTj0iaGVpZ2h0Ij4xNzwvSTMyPjwvTVM+PC9PYmo+PC9NUz48L09iaj48L0VuPjxFbj48STMyIE49IktleSI+NjwvSTMyPjxPYmogTj0iVmFsdWUiIFJlZklkPSIxNCI+PE1TPjxTIE49IlQiPlN5c3RlbS5NYW5hZ2VtZW50LkF1dG9tYXRpb24uSG9zdC5TaXplPC9TPjxPYmogTj0iViIgUmVmSWQ9IjE1Ij48TVM+PEkzMiBOPSJ3aWR0aCI+MTU2PC9JMzI+PEkzMiBOPSJoZWlnaHQiPjE3PC9JMzI+PC9NUz48L09iaj48L01TPjwvT2JqPjwvRW4+PEVuPjxJMzIgTj0iS2V5Ij41PC9JMzI+PE9iaiBOPSJWYWx1ZSIgUmVmSWQ9IjE2Ij48TVM+PFMgTj0iVCI+U3lzdGVtLk1hbmFnZW1lbnQuQXV0b21hdGlvbi5Ib3N0LlNpemU8L1M+PE9iaiBOPSJWIiBSZWZJZD0iMTciPjxNUz48STMyIE49IndpZHRoIj4xNTY8L0kzMj48STMyIE49ImhlaWdodCI+MTc8L0kzMj48L01TPjwvT2JqPjwvTVM+PC9PYmo+PC9Fbj48RW4+PEkzMiBOPSJLZXkiPjQ8L0kzMj48T2JqIE49IlZhbHVlIiBSZWZJZD0iMTgiPjxNUz48UyBOPSJUIj5TeXN0ZW0uSW50MzI8L1M+PEkzMiBOPSJWIj4xMDA8L0kzMj48L01TPjwvT2JqPjwvRW4+PEVuPjxJMzIgTj0iS2V5Ij4zPC9JMzI+PE9iaiBOPSJWYWx1ZSIgUmVmSWQ9IjE5Ij48TVM+PFMgTj0iVCI+U3lzdGVtLk1hbmFnZW1lbnQuQXV0b21hdGlvbi5Ib3N0LkNvb3JkaW5hdGVzPC9TPjxPYmogTj0iViIgUmVmSWQ9IjIwIj48TVM+PEkzMiBOPSJ4Ij4wPC9JMzI+PEkzMiBOPSJ5Ij4wPC9JMzI+PC9NUz48L09iaj48L01TPjwvT2JqPjwvRW4+PEVuPjxJMzIgTj0iS2V5Ij4yPC9JMzI+PE9iaiBOPSJWYWx1ZSIgUmVmSWQ9IjIxIj48TVM+PFMgTj0iVCI+U3lzdGVtLk1hbmFnZW1lbnQuQXV0b21hdGlvbi5Ib3N0LkNvb3JkaW5hdGVzPC9TPjxPYmogTj0iViIgUmVmSWQ9IjIyIj48TVM+PEkzMiBOPSJ4Ij4wPC9JMzI+PEkzMiBOPSJ5Ij4xPC9JMzI+PC9NUz48L09iaj48L01TPjwvT2JqPjwvRW4+PEVuPjxJMzIgTj0iS2V5Ij4xPC9JMzI+PE9iaiBOPSJWYWx1ZSIgUmVmSWQ9IjIzIj48TVM+PFMgTj0iVCI+U3lzdGVtLkNvbnNvbGVDb2xvcjwvUz48STMyIE49IlYiPi0xPC9JMzI+PC9NUz48L09iaj48L0VuPjxFbj48STMyIE49IktleSI+MDwvSTMyPjxPYmogTj0iVmFsdWUiIFJlZklkPSIyNCI+PE1TPjxTIE49IlQiPlN5c3RlbS5Db25zb2xlQ29sb3I8L1M+PEkzMiBOPSJWIj4tMTwvSTMyPjwvTVM+PC9PYmo+PC9Fbj48L0RDVD48L09iaj48L01TPjwvT2JqPjxCIE49Il91c2VSdW5zcGFjZUhvc3QiPmZhbHNlPC9CPjwvTVM+PC9PYmo+PC9NUz48L09iaj4=</Data>" |
            ConvertTo-PSRPPacket

        $packet.Type | Should-Be Data
        $packet.PSGuid | Should-Be "00000000-0000-0000-0000-000000000000"
        $packet.Stream | Should-Be "Default"

        $packet.Fragments | Should-BeCollection -Count 2
        $packet.Fragments[0].ObjectId | Should-Be 1
        $packet.Fragments[0].FragmentId | Should-Be 0
        $packet.Fragments[0].Start | Should-BeTrue
        $packet.Fragments[0].End | Should-BeTrue

        $packet.Fragments[1].ObjectId | Should-Be 2
        $packet.Fragments[1].FragmentId | Should-Be 0
        $packet.Fragments[1].Start | Should-BeTrue
        $packet.Fragments[1].End | Should-BeTrue

        $packet.Messages | Should-BeCollection -Count 2
        $packet.Messages[0].Destination | Should-Be Server
        $packet.Messages[0].MessageType | Should-Be SessionCapability
        $packet.Messages[0].RunspacePoolId | Should-Be a6fa5eaf-2efa-4b3e-806f-7be252a39be9
        $packet.Messages[0].PipelineId | Should-Be "00000000-0000-0000-0000-000000000000"
        $packet.Messages[0].Data | Should-BeLikeString '<Obj RefId="0">*'

        $packet.Messages[1].Destination | Should-Be Server
        $packet.Messages[1].MessageType | Should-Be InitRunspacePool
        $packet.Messages[1].RunspacePoolId | Should-Be a6fa5eaf-2efa-4b3e-806f-7be252a39be9
        $packet.Messages[1].PipelineId | Should-Be "00000000-0000-0000-0000-000000000000"
        $packet.Messages[1].Data | Should-BeLikeString '<Obj RefId="0">*'

        $packet.Raw | Should-BeLikeString "<Data Stream='Default' PSGuid='00000000-0000-0000-0000-000000000000'>*</Data>"
    }

    It "Parses packets across multiple fragments" {
        # Produced by running ('a' * 65KB) in a pipeline
        $packets = Get-Content -LiteralPath ([Path]::Combine($PSScriptRoot, 'data', 'large-psrp-packet.txt')) | ConvertTo-PSRPPacket

        $packets | Should-BeCollection -Count 3
        $packets[0].Type | Should-Be Data
        $packets[0].PSGuid | Should-Be c8cf479a-daf8-4b7c-872c-95a22e6d344f
        $packets[0].Stream | Should-Be Default
        $packets[0].Fragments | Should-BeCollection -Count 1
        $packets[0].Fragments[0].ObjectId | Should-Be 327
        $packets[0].Fragments[0].FragmentId | Should-Be 0
        $packets[0].Fragments[0].Start | Should-BeTrue
        $packets[0].Fragments[0].End | Should-BeFalse
        $packets[0].Messages | Should-BeCollection -Count 0

        $packets[1].Type | Should-Be Data
        $packets[1].PSGuid | Should-Be c8cf479a-daf8-4b7c-872c-95a22e6d344f
        $packets[1].Stream | Should-Be Default
        $packets[1].Fragments | Should-BeCollection -Count 1
        $packets[1].Fragments[0].ObjectId | Should-Be 327
        $packets[1].Fragments[0].FragmentId | Should-Be 1
        $packets[1].Fragments[0].Start | Should-BeFalse
        $packets[1].Fragments[0].End | Should-BeFalse
        $packets[1].Messages | Should-BeCollection -Count 0

        $packets[2].Type | Should-Be Data
        $packets[2].PSGuid | Should-Be c8cf479a-daf8-4b7c-872c-95a22e6d344f
        $packets[2].Stream | Should-Be Default
        $packets[2].Fragments | Should-BeCollection -Count 1
        $packets[2].Fragments[0].ObjectId | Should-Be 327
        $packets[2].Fragments[0].FragmentId | Should-Be 2
        $packets[2].Fragments[0].Start | Should-BeFalse
        $packets[2].Fragments[0].End | Should-BeTrue
        $packets[2].Messages | Should-BeCollection -Count 1
        $packets[2].Messages[0].Destination | Should-Be Client
        $packets[2].Messages[0].MessageType | Should-Be PipelineOutput
        $packets[2].Messages[0].RunspacePoolId | Should-Be 0f3f9c78-7ad4-4615-ac8d-72cbc42e225d
        $packets[2].Messages[0].PipelineId | Should-Be c8cf479a-daf8-4b7c-872c-95a22e6d344f
        $packets[2].Messages[0].Data | Should-BeLikeString "<S>a*</S>"
        $packets[2].Messages[0].Data.Length | Should-Be 66567  # 65KB of 'a' plus the XML wrapper
    }

    It "Sets the destination of a <Type> packet to <Expected>" -ForEach @(
        # The client sends the commands and the server acknowledges them.
        @{ Type = 'Command'; Expected = 'Server' }
        @{ Type = 'Signal'; Expected = 'Server' }
        @{ Type = 'Close'; Expected = 'Server' }
        @{ Type = 'DataAck'; Expected = 'Client' }
        @{ Type = 'CommandAck'; Expected = 'Client' }
        @{ Type = 'SignalAck'; Expected = 'Client' }
        @{ Type = 'CloseAck'; Expected = 'Client' }
    ) {
        $packet = "<$Type PSGuid='00000000-0000-0000-0000-000000000000' />" | ConvertTo-PSRPPacket

        $packet.Destination | Should-Be ([RemoteWrench.PSRPDestination]$Expected)
    }

    It "Does not set the destination of an unknown packet" {
        $packet = "<Unknown PSGuid='00000000-0000-0000-0000-000000000000' />" | ConvertTo-PSRPPacket

        $packet.Destination | Should-BeNull
    }

    It "Sets the destination of a fragment from the message header" {
        # Only the start fragment has the message header.
        $packets = Get-TestData large-psrp-packet.txt | ConvertTo-PSRPPacket

        $packets.Destination | Should-BeCollection @(
            [RemoteWrench.PSRPDestination]::Client
            [RemoteWrench.PSRPDestination]::Client
            [RemoteWrench.PSRPDestination]::Client
        )
    }

    It "Ignores whitespace only lines" {
        $packet = '', "<DataAck Stream='Default' PSGuid='00000000-0000-0000-0000-000000000000' />", ' ' | ConvertTo-PSRPPacket
        $packet | Should-BeCollection -Count 1

        $packet.Type | Should-Be DataAck
        $packet.PSGuid | Should-Be 00000000-0000-0000-0000-000000000000
        $packet.Stream | Should-Be Default
        $packet.Fragments | Should-BeCollection -Count 0
        $packet.Messages | Should-BeCollection -Count 0
        $packet.Raw | Should-Be "<DataAck Stream='Default' PSGuid='00000000-0000-0000-0000-000000000000' />"
    }

    It "Missing Stream value" {
        $packet = "<DataAck PSGuid='00000000-0000-0000-0000-000000000000' />" | ConvertTo-PSRPPacket
        $packet | Should-BeCollection -Count 1

        $packet.Type | Should-Be DataAck
        $packet.PSGuid | Should-Be 00000000-0000-0000-0000-000000000000
        $packet.Stream | Should-BeNull
        $packet.Fragments | Should-BeCollection -Count 0
        $packet.Messages | Should-BeCollection -Count 0
        $packet.Raw | Should-Be "<DataAck PSGuid='00000000-0000-0000-0000-000000000000' />"
    }

    It "Message data contains UTF-8 BOM" {
        $rawPacket = Get-PSRPPacket -Destination Client -MessageType PipelineOutput -Data "$([char]0xFEFF)<S>a</S>"
        $packet = $rawPacket | ConvertTo-PSRPPacket

        $packet.Type | Should-Be Data
        $packet.PSGuid | Should-Be 00000000-0000-0000-0000-000000000000
        $packet.Stream | Should-Be Default
        $packet.Fragments | Should-BeCollection -Count 1
        $packet.Fragments[0].ObjectId | Should-Be 1
        $packet.Fragments[0].FragmentId | Should-Be 0
        $packet.Fragments[0].Start | Should-BeTrue
        $packet.Fragments[0].End | Should-BeTrue
        $packet.Messages | Should-BeCollection -Count 1
        $packet.Messages[0].Destination | Should-Be Client
        $packet.Messages[0].MessageType | Should-Be PipelineOutput
        $packet.Messages[0].RunspacePoolId | Should-Be 00000000-0000-0000-0000-000000000000
        $packet.Messages[0].PipelineId | Should-Be 00000000-0000-0000-0000-000000000000
        $packet.Messages[0].Data | Should-Be "<S>a</S>"
        $packet.Messages[0].Data.Length | Should-Be 8 # Excludes the 3 byte UTF-8 BOM
    }

    It "Emits error for invalid XML" {
        $err = $null
        $packet = 'invalid', "<DataAck Stream='Default' PSGuid='00000000-0000-0000-0000-000000000000' />" | ConvertTo-PSRPPacket -ErrorAction SilentlyContinue -ErrorVariable err
        $packet | Should-BeCollection -Count 1

        $packet.Type | Should-Be DataAck
        $packet.PSGuid | Should-Be 00000000-0000-0000-0000-000000000000
        $packet.Stream | Should-Be Default
        $packet.Fragments | Should-BeCollection -Count 0
        $packet.Messages | Should-BeCollection -Count 0

        $err | Should-BeCollection -Count 1
        [string]$err[0] | Should-Be "Failed to parse line 'invalid': Data at the root level is invalid. Line 1, position 1."
        $err[0].FullyQualifiedErrorId | Should-Be "ParseError,RemoteWrench.Commands.ConvertToPSRPPacket"
        $err[0].CategoryInfo.Category | Should-Be InvalidData
        $err[0].TargetObject | Should-Be 'invalid'
    }

    It "Emits error for missing PSGuid value" {
        $err = $null
        $packet = "<DataAck Stream='Default' />" | ConvertTo-PSRPPacket -ErrorAction SilentlyContinue -ErrorVariable err
        $packet | Should-BeCollection -Count 0

        $err | Should-BeCollection -Count 1
        [string]$err[0] | Should-MatchString "Failed to parse line '.*': Missing PSGuid attribute"
        $err[0].FullyQualifiedErrorId | Should-Be "ParseError,RemoteWrench.Commands.ConvertToPSRPPacket"
        $err[0].CategoryInfo.Category | Should-Be InvalidData
    }

    It "Emits error for invalid PSGuid value" {
        $err = $null
        $packet = "<DataAck Stream='Default' PSGuid='invalid' />" | ConvertTo-PSRPPacket -ErrorAction SilentlyContinue -ErrorVariable err
        $packet | Should-BeCollection -Count 0

        $err | Should-BeCollection -Count 1
        [string]$err[0] | Should-MatchString "Failed to parse line '.*': Invalid PSGuid value: invalid"
        $err[0].FullyQualifiedErrorId | Should-Be "ParseError,RemoteWrench.Commands.ConvertToPSRPPacket"
        $err[0].CategoryInfo.Category | Should-Be InvalidData
    }

    It "Parses message with data '<_>' shorter than a UTF-8 BOM" -ForEach '', 'a', 'ab' {
        $packet = Get-PSRPPacket -Destination Server -MessageType EndOfPipelineInput -Data $_ |
            ConvertTo-PSRPPacket -ErrorAction Stop

        $packet.Messages | Should-BeCollection -Count 1
        $packet.Messages[0].MessageType | Should-Be EndOfPipelineInput
        $packet.Messages[0].Data | Should-Be $_
    }

    It "Parses message with only a UTF-8 BOM" {
        $packet = Get-PSRPPacket -Destination Server -MessageType EndOfPipelineInput -Data "$([char]0xFEFF)" |
            ConvertTo-PSRPPacket -ErrorAction Stop

        $packet.Messages | Should-BeCollection -Count 1
        $packet.Messages[0].Data | Should-Be ''
    }

    It "Reassembles fragments in the same Data packet" {
        $msg = New-PSRPMessage -Destination Client -MessageType PipelineOutput -Data '<S>value</S>'
        $bytes = (New-PSRPFragment -Blob $msg[0..19] -ObjectId 5 -FragmentId 0 -Start) +
            (New-PSRPFragment -Blob $msg[20..29] -ObjectId 5 -FragmentId 1) +
            (New-PSRPFragment -Blob $msg[30..($msg.Length - 1)] -ObjectId 5 -FragmentId 2 -End)
        $packet = ConvertTo-DataPacket -Bytes $bytes | ConvertTo-PSRPPacket -ErrorAction Stop

        $packet.Fragments | Should-BeCollection -Count 3
        $packet.Messages | Should-BeCollection -Count 1
        $packet.Messages[0].MessageType | Should-Be PipelineOutput
        $packet.Messages[0].Data | Should-Be '<S>value</S>'
    }

    It "Reassembles interleaved fragments with the same object id from different PSGuids" {
        # Object ids are only unique within the sending process, the client and
        # server can both have a fragmented message with the same id in flight.
        $guid1 = [Guid]::NewGuid()
        $guid2 = [Guid]::NewGuid()
        $msg1 = New-PSRPMessage -Destination Server -MessageType PipelineInput -Data '<S>input</S>'
        $msg2 = New-PSRPMessage -Destination Client -MessageType PipelineOutput -Data '<S>output</S>'

        $packets = @(
            ConvertTo-DataPacket -PSGuid $guid1 -Bytes (New-PSRPFragment -Blob $msg1[0..29] -ObjectId 1 -Start)
            ConvertTo-DataPacket -PSGuid $guid2 -Bytes (New-PSRPFragment -Blob $msg2[0..29] -ObjectId 1 -Start)
            ConvertTo-DataPacket -PSGuid $guid1 -Bytes (New-PSRPFragment -Blob $msg1[30..($msg1.Length - 1)] -ObjectId 1 -FragmentId 1 -End)
            ConvertTo-DataPacket -PSGuid $guid2 -Bytes (New-PSRPFragment -Blob $msg2[30..($msg2.Length - 1)] -ObjectId 1 -FragmentId 1 -End)
        ) | ConvertTo-PSRPPacket -ErrorAction Stop

        $packets | Should-BeCollection -Count 4
        $packets[2].Messages | Should-BeCollection -Count 1
        $packets[2].Messages[0].MessageType | Should-Be PipelineInput
        $packets[2].Messages[0].Data | Should-Be '<S>input</S>'
        $packets[3].Messages | Should-BeCollection -Count 1
        $packets[3].Messages[0].MessageType | Should-Be PipelineOutput
        $packets[3].Messages[0].Data | Should-Be '<S>output</S>'
    }

    It "Emits error for <Name>" -ForEach @(
        @{
            Name = 'invalid base64'
            Packets = { "<Data Stream='Default' PSGuid='00000000-0000-0000-0000-000000000000'>not base64!</Data>" }
            Expected = 'Data packet does not contain valid base64 content'
        }
        @{
            Name = 'blob length exceeding the packet'
            Packets = { ConvertTo-DataPacket -Bytes (New-PSRPFragment -Blob ([byte[]]::new(5)) -BlobLength 100 -Start -End) }
            Expected = 'PSRP fragment Obj=1 Frag=0 has a blob length of 100 but only 5 bytes remain in the Data packet'
        }
        @{
            Name = 'negative blob length'
            Packets = { ConvertTo-DataPacket -Bytes (New-PSRPFragment -Blob ([byte[]]::new(5)) -BlobLength -1 -Start -End) }
            Expected = 'PSRP fragment Obj=1 Frag=0 has a blob length of -1 but only 5 bytes remain in the Data packet'
        }
        @{
            Name = 'trailing bytes'
            Packets = {
                $msg = New-PSRPMessage -Destination Client -MessageType PipelineOutput -Data '<S>a</S>'
                ConvertTo-DataPacket -Bytes ((New-PSRPFragment -Blob $msg -Start -End) + [byte[]]::new(5))
            }
            Expected = 'Data packet has 5 trailing bytes, expecting a 21 byte PSRP fragment header'
        }
        @{
            Name = 'message shorter than the header'
            Packets = { ConvertTo-DataPacket -Bytes (New-PSRPFragment -Blob ([byte[]]::new(10)) -Start -End) }
            Expected = 'PSRP message is 10 bytes, expecting at least the 40 byte message header'
        }
        @{
            Name = 'fragment without a start fragment'
            Packets = { ConvertTo-DataPacket -Bytes (New-PSRPFragment -Blob ([byte[]]::new(10)) -ObjectId 5 -FragmentId 1 -End) }
            Expected = 'PSRP fragment Obj=5 Frag=1 was received without a start fragment'
        }
        @{
            Name = 'fragment with a different PSGuid to the start fragment'
            Packets = {
                ConvertTo-DataPacket -PSGuid ([Guid]::NewGuid()) -Bytes (New-PSRPFragment -Blob ([byte[]]::new(10)) -ObjectId 5 -Start)
                ConvertTo-DataPacket -PSGuid ([Guid]::NewGuid()) -Bytes (New-PSRPFragment -Blob ([byte[]]::new(40)) -ObjectId 5 -FragmentId 1 -End)
            }
            Expected = 'PSRP fragment Obj=5 Frag=1 was received without a start fragment'
        }
    ) {
        $err = $null
        $lines = @(& $Packets)
        $packet = $lines | ConvertTo-PSRPPacket -ErrorAction SilentlyContinue -ErrorVariable err

        # Only the start fragments, if any, are output.
        $packet | Should-BeCollection -Count ($lines.Count - 1)
        $err | Should-BeCollection -Count 1
        $err[0].Exception | Should-HaveType ([InvalidDataException])
        $err[0].Exception.Message | Should-Be $Expected
        [string]$err[0] | Should-Be "Failed to parse line '$($lines[-1])': $Expected"
        $err[0].FullyQualifiedErrorId | Should-Be "ParseError,RemoteWrench.Commands.ConvertToPSRPPacket"
        $err[0].CategoryInfo.Category | Should-Be InvalidData
        $err[0].TargetObject | Should-Be $lines[-1]
    }

    It "Emits error for a missing fragment" {
        $msg = New-PSRPMessage -Destination Client -MessageType PipelineOutput -Data '<S>value</S>'
        $lines = @(
            ConvertTo-DataPacket -Bytes (New-PSRPFragment -Blob $msg[0..19] -ObjectId 5 -FragmentId 0 -Start)
            # Frag=1 is missing
            ConvertTo-DataPacket -Bytes (New-PSRPFragment -Blob $msg[20..29] -ObjectId 5 -FragmentId 2)
            ConvertTo-DataPacket -Bytes (New-PSRPFragment -Blob $msg[30..($msg.Length - 1)] -ObjectId 5 -FragmentId 3 -End)
        )

        $err = $null
        $packet = $lines | ConvertTo-PSRPPacket -ErrorAction SilentlyContinue -ErrorVariable err

        $packet | Should-BeCollection -Count 1
        $packet.Messages | Should-BeCollection -Count 0

        # The partial message is dropped so the following fragments of the same object fail too.
        $err | Should-BeCollection -Count 2
        $err[0].Exception.Message | Should-Be 'PSRP fragment Obj=5 Frag=2 was received but expected Frag=1'
        $err[1].Exception.Message | Should-Be 'PSRP fragment Obj=5 Frag=3 was received without a start fragment'
    }
}
