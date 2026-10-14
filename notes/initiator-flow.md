# 이니시에이터 코드 흐름 (SPDK, RDMA)

`nvme_rdma_`로 시작하는 함수는 `lib/nvme/nvme_rdma.c`, `spdk_rdma_provider_`는 `lib/rdma_provider/`, `spdk_rdma_utils_`는 `lib/rdma_utils/`에 있다. 나머지는 함수 옆에 파일을 적었다.

## admin 작업 (블랙박스)

원격 SSD를 쓸 수 있게 켜고 정보를 묻는 단계다. 끝나면 컨트롤러가 켜지고, 컨트롤러 번호(cntlid), 블록 크기, 쓸 수 있는 I/O 큐 개수를 알게 된다. 앱은 `spdk_nvme_connect(타겟 주소)`(`lib/nvme/nvme.c`)만 부르면 되고, 자세한 단계는 `lib/nvme/nvme_ctrlr.c`의 `nvme_ctrlr_process_init`에 있다. admin 큐도 아래 I/O 큐와 같은 과정으로 연결된다.

## I/O 큐 하나 연결

앱은 `spdk_nvme_ctrlr_alloc_io_qpair(컨트롤러, 옵션)`(`lib/nvme/nvme_ctrlr.c`)만 부른다. 안에서는 아래 순서로 진행된다.

1. **큐 구조체를 만든다** (`nvme_rdma_ctrlr_create_qpair`).
2. **어느 네트워크 카드를 쓸지 찾는다.** 타겟 IP로 가려면 어느 카드를 써야 하는지, 경로는 어떤지 알아낸다. QP·CQ는 그 카드 위에 만들어야 해서 먼저 한다. rdma_cm에 요청하면(`nvme_rdma_ctrlr_connect_qpair` → `nvme_rdma_resolve_addr`) 결과가 이벤트로 온다.
3. **QP와 CQ를 만든다.** 찾은 카드 위에 QP(송신 큐·수신 큐)와 CQ(완료 큐)를 CPU 메모리에 만든다(`nvme_rdma_qpair_init`). 보통은 rdma_cm이 QP를 만들어 관리까지 해 준다. SPDK가 QP를 직접 만드는 경우(`mlx5_dv`, `lib/rdma_provider/`)에는 rdma_cm이 그 QP를 관리하지 못하므로, 5번에서 SPDK가 대신 처리한다.
4. **타겟에 연결을 요청한다.** 큐 번호, 큐 크기, cntlid를 실어 연결을 요청한다(`nvme_rdma_connect` → `rdma_connect`).
5. **연결을 마무리한다.** 타겟이 받아들이면 이벤트가 온다(`nvme_rdma_qpair_process_cm_event`). QP는 만든 직후에는 통신할 수 없어서 사용 가능 상태로 바꿔야 한다(INIT→RTR→RTS). rdma_cm이 만든 QP는 rdma_cm이 바꿔 준다. SPDK가 직접 만든 QP는 SPDK가 rdma_cm에게서 연결 정보를 받아 직접 바꾸고, 연결 완료를 rdma_cm에 알린다(`spdk_rdma_provider_qp_complete_connect`).
6. **메모리를 등록하고 버퍼를 준비한다** (`nvme_rdma_connect_established`). 네트워크 카드는 등록된 메모리에만 직접 접근할 수 있다. SPDK는 여기서 자기 메모리를 전부 카드에 등록해 두고(`spdk_rdma_utils_create_mem_map`, `lib/rdma_utils/rdma_utils.c`), 나중에 생기는 메모리도 자동으로 등록한다. 등록 대상은 세 가지다.
   - 명령 버퍼(`nvme_rdma_create_reqs`): 보낼 명령을 담는 곳. 보낼 때 카드가 여기서 명령을 읽어 간다.
   - 완료 버퍼(`nvme_rdma_create_rsps`): 타겟이 보낸 완료가 들어오는 곳. 수신 큐는 "다음 메시지를 어느 버퍼에 담을지" 적어 두는 목록인데, 여기에 완료 버퍼들을 미리 올려 둔다(`nvme_rdma_qpair_submit_recvs`). 완료가 도착하면 카드가 목록 맨 앞 버퍼에 써 넣는다.
   - 앱의 데이터 버퍼: 타겟이 읽은 데이터를 써 넣는 곳. 앱이 SPDK 함수(`spdk_dma_malloc` 등)로 할당한 메모리면 여기서 함께 등록된다.
7. **이 큐를 컨트롤러에 등록한다.** 이 큐로 Fabrics Connect 명령을 보내 컨트롤러의 몇 번 큐인지 등록한다(`nvme_fabric_qpair_connect_async`, `lib/nvme/nvme_fabric.c`). 응답이 오면 사용 가능 상태가 된다.

2~7은 한 번에 끝나지 않고, 이벤트나 응답을 기다리며 단계를 넘어간다(`nvme_rdma_ctrlr_connect_qpair_poll`).

## 읽기 한 번

보내는 쪽:

1. **앱이 읽기를 요청한다.** 큐, 시작 블록, 블록 수, 데이터를 받을 버퍼, 끝나면 부를 콜백을 넘긴다(`spdk_nvme_ns_cmd_read`, `lib/nvme/nvme_ns_cmd.c`).
2. **요청이 연결 방식별 코드로 넘어간다.** 읽기 함수는 연결 방식과 상관없이 같고, 실제로 보내는 일은 연결 방식별 파일이 한다(PCIe는 `nvme_pcie.c`, RDMA는 `nvme_rdma.c`). 여기서는 위에서 큐를 연결한 `nvme_rdma.c`로 넘어간다: `nvme_qpair_submit_request`(`lib/nvme/nvme_qpair.c`) → `nvme_transport_qpair_submit_request`(`lib/nvme/nvme_transport.c`) → `nvme_rdma_qpair_submit_request`
3. **명령을 완성한다** (`nvme_rdma_req_init`). 비어 있는 명령 버퍼를 하나 꺼내 64바이트 명령을 채운다.
   - 블록 번호
   - 데이터 버퍼의 주소와 키. 키는 메모리를 등록할 때 받은 값으로, 타겟이 그 메모리에 쓸 수 있게 해 주는 허가값이다(`nvme_rdma_get_memory_translation`으로 찾는다).
   - 명령 번호(cid). 꺼낸 명령 버퍼의 번호를 그대로 쓴다.
4. **타겟으로 보낸다.** 명령을 QP의 송신 큐에 넣고, 네트워크 카드에 보낼 게 있다고 알린다(`spdk_rdma_provider_qp_queue_send_wrs`, `spdk_rdma_provider_qp_flush_send_wrs`).

그다음 타겟이 SSD에서 읽은 데이터를 앱 버퍼에 직접 써 넣고(RDMA write), 완료를 보낸다. 이니시에이터 코드는 이 사이에 하는 일이 없다.

받는 쪽:

5. **앱이 완료 확인을 계속 부른다** (`spdk_nvme_qpair_process_completions`, `lib/nvme/nvme_qpair.c` → `nvme_rdma_qpair_process_completions`).
6. **CQ에서 완료 항목을 꺼낸다** (`nvme_rdma_qpair_process_cq_completions` → `spdk_rdma_utils_poll_cq`).
7. **어느 요청이 끝났는지 찾는다.** 완료 버퍼에 들어온 명령 번호로 요청을 찾고(`nvme_rdma_process_recv_completion`, `rdma_reqs[cid]`), 다 쓴 완료 버퍼는 수신 큐에 다시 올려 둔다. 명령 버퍼는 네트워크 카드가 다 읽어 간 뒤에야 다시 쓸 수 있어서, 송신 완료(`nvme_rdma_process_send_completion`)까지 와야 요청을 끝낸다.
8. **앱의 콜백을 부른다** (`nvme_rdma_request_ready`). 이때 데이터는 이미 앱 버퍼에 와 있다.
