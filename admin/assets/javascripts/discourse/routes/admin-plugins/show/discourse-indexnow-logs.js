import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowDiscourseIndexNowLogs extends DiscourseRoute {
  model() {
    return ajax("/admin/plugins/discourse-indexnow/logs.json", {
      data: this.controllerFor(this.routeName).logRequestParams,
    });
  }

  setupController(controller, model) {
    controller.setProperties({
      model,
      data: model,
    });
    controller.resumeBatchPolling();
  }

  deactivate() {
    this.controller?.stopBatchPolling();
    super.deactivate(...arguments);
  }
}
